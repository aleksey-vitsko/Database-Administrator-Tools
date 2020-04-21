


create or alter procedure ScriptLoginPermissions (@LoginName as varchar(150)) as begin

set nocount on


/****************************************************** ScriptLoginPermissions *********************************************************

Version: 1.06

History:

--> 2020-01-06 - Aleksey Vitsko - even if login is sysadmin, still show all other permissions
--> 2019-02-01 - Aleksey Vitsko - added support for master, msdb, model databases
--> 2019-02-01 - Aleksey Vitsko - look into ONLINE state databases only
--> 2018-12-05 - Aleksey Vitsko - fixed bug related to xp_logininfo sp and SQL logins
--> 2018-11-19 - Aleksey Vitsko - added support for Active Directory group login membership: show information about AD group memberships
--> 2018-11-19 - Aleksey Vitsko - added support for column level permissions
--> 2018-05-01 - Aleksey Vitsko - created procedure


***************************************************************************************************************************************/





------------------------------------------------- Declare Variables Section ----------------------------------------------

-- variables
declare 
	@server_principal_id		smallint, 
	@sid						varbinary(150), 
	@sid_varchar				varchar(150),
	@database_principal_id		smallint, 
	@database_user_name			varchar(150), 
	@database_name				varchar(150), 
	@sql						varchar(max),
	@EngineEdition				varchar(300) = cast(serverproperty('EngineEdition') as varchar(300))

declare @user_info table (
	Indicator				bit,
	[name]					varchar(150),
	principal_id			smallint)

declare @database_roles table (
	[db_role_name]			varchar(150))


declare @database_permissions table (
	class_desc				varchar(150),
	[object_name]			varchar(150),
	[permission_name]		varchar(150),
	state_desc				varchar(150),
	column_name				varchar(150))


declare @AD_Groups table (
	tAccountName				varchar(150),
	tType						varchar(50),
	tPrivilege					varchar(50),
	tMappedLoginName			varchar(150),
	tPermissionPath				varchar(150))





-- result table that will contain all statements
declare @Result table (
	SQLStatement			varchar(max))


	
-- azure or sql server
if @EngineEdition not in ('5','6','8') begin
	print ''
end



	-- check if specified login exists
	if not exists (select * from sys.server_principals where name = @LoginName) begin
		print 'Specified login -- ' + @LoginName + ' -- does not exist'
		return
	end 


	-- insert login name
	insert into @Result (SQLStatement)
	select '------------------------ ' + @LoginName +  ' --------------------------'
	
	insert into @Result (SQLStatement)
	select ''

	-- login type
	insert into @Result (SQLStatement)
	select '-- Login type: ' + (select cast(type_desc as varchar) from sys.server_principals where name = @LoginName)

	insert into @Result (SQLStatement)
	select ''



	-- AD group membership
	if (select [type] from sys.server_principals where [name] = @LoginName) = 'U' begin

		insert into @AD_Groups (tAccountName, tType, tPrivilege, tMappedLoginName, tPermissionPath)
		exec xp_logininfo @LoginName,'all'

		if exists (select * from @AD_Groups where tPermissionPath is not NULL) begin

			insert into @Result (SQLStatement)
			select '-- Active Directory group login membership:'
		 
			insert into @Result (SQLStatement)
			select '-- [' + @LoginName + '] is a member of AD group: [' + tPermissionPath + ']'
			from @AD_Groups
			where tPermissionPath is not NULL
			order by tPermissionPath

			insert into @Result (SQLStatement)
			select ''

		end

	end

	-- get sid, principal_id of login
	select	@sid = [sid],
			@server_principal_id = [principal_id]
	from sys.server_principals 
	where [name] = @LoginName 

	set @sid_varchar = convert(varchar(max), @sid, 1 )
	

	-- get server level permissions
	insert into @Result (SQLStatement)
	select 'use master'

	insert into @Result (SQLStatement)
	select state_desc + ' ' + [permission_name] + ' to [' + @LoginName + ']'
	from sys.server_permissions
	where grantee_principal_id = @server_principal_id


	
	-- for sysadmins, special treatment
	if exists (select * 
				from sys.server_role_members srm
					join sys.server_principals sp on
						srm.role_principal_id = sp.principal_id
						and sp.[name] = 'sysadmin'
				where srm.member_principal_id = @server_principal_id) begin
		insert into @Result (SQLStatement)
		select 'alter server role [sysadmin] add member [' + @LoginName + ']'

		insert into @Result (SQLStatement)
		select '-- !!! WARNING: login [' + @LoginName + ']' + ' is a member of SYSADMIN server role'

		insert into @Result (SQLStatement)
		select '-- !!! WARNING: [' + @LoginName + ']' + ' can do everything on this instance, you can ignore below permissions'

		-- goto show_results -- uncomment this line if you do not want to show any other permissions for sysadmin members
		
	end
	


	-- server role membership
	if exists (select * 
				from sys.server_role_members srm
					join sys.server_principals sp on
						srm.role_principal_id = sp.principal_id
						and sp.[name] <> 'sysadmin'
				where srm.member_principal_id = @server_principal_id) begin
		insert into @Result (SQLStatement)
		select 'alter server role [' + sp.name + '] add member [' + @LoginName + ']'
		from sys.server_role_members srm
			join sys.server_principals sp on
				srm.role_principal_id = sp.principal_id
		where srm.member_principal_id = @server_principal_id
	end

	
	---------------------- database cursor ------------------------

	declare Database_Cursor cursor local fast_forward for
	select [name]
	from sys.databases
	where	[name] not in ('tempdb')
			and state_desc in ('ONLINE')

	open Database_Cursor

	fetch next from Database_Cursor 
	into @database_name

	while @@FETCH_STATUS = 0 begin

		set @sql = 'if not exists (select * from ' + @database_name + '.sys.database_principals where [sid] = ' + @sid_varchar + ') select 0,NULL,NULL else select 1,[name],principal_id from ' + @database_name + '.sys.database_principals where [sid] = ' + @sid_varchar 

		insert into @user_info (Indicator,[name],principal_id)
		exec (@sql)

		-- if no database principal found for this login, move to next database
		if (select Indicator from @user_info) = 0 begin 
			goto next_database
		end

		-- get current db user name / principal id for current login
		select 
			@database_principal_id = principal_id, 
			@database_user_name	= [name]
		from @user_info


		-- create in current db for current login
		insert into @Result (SQLStatement)
		select 'use ' + @database_name
		union select ''

		insert into @Result (SQLStatement)
		select 'create user [' + @database_user_name + '] for login [' + @LoginName + ']'

		
		-- database role membership
		set @sql = 'select p.[name]
		from ' + @database_name + '.sys.database_role_members drm
			join ' + @database_name + '.sys.database_principals p on
				role_principal_id = principal_id
		where	drm.member_principal_id = ' + cast(@database_principal_id as varchar)

		insert into @database_roles (db_role_name)
		exec (@sql)


		-- insert add db role member statements
		insert into @Result (SQLStatement)
		select 'alter role [' + db_role_name + '] add member [' + @database_user_name + ']'
		from @database_roles

		
		-- database level permissions
		set @sql = 'select class_desc, 
			case class_desc 
				when ''DATABASE'' then ''DB''
				when ''OBJECT_OR_COLUMN'' then o.[name]
				when ''SCHEMA'' then s.[name] 
				when ''TYPE'' then t.[name]
			end, 
			[permission_name],
			state_desc,
			c.[name] 
		from ' + @database_name + '.sys.database_permissions dp
			left join ' + @database_name + '.sys.objects o on
				dp.major_id = o.[object_id]
			left join ' + @database_name + '.sys.schemas s on
				dp.major_id = s.[schema_id]
			left join ' + @database_name + '.sys.types t on
				dp.major_id = t.[user_type_id]
			left join ' + @database_name + '.sys.columns c on
				dp.major_id = c.[object_id]
				and dp.minor_id = c.[column_id]
		where grantee_principal_id = ' + cast(@database_principal_id as varchar)
				

		insert into @database_permissions (class_desc,[object_name],[permission_name],state_desc,column_name)
		exec (@sql)

		
		-- insert database level permissions
		insert into @Result (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' to [' + @database_user_name + ']'
		from @database_permissions
		where class_desc = 'DATABASE'

		insert into @Result (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' on schema::' + [object_name] + ' to [' + @database_user_name + ']'
		from @database_permissions
		where class_desc = 'SCHEMA'

		insert into @Result (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' on ' + [object_name] + ' to [' + @database_user_name + ']'
		from @database_permissions
		where	class_desc = 'OBJECT_OR_COLUMN'
				and column_name is NULL

		insert into @Result (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' on ' + [object_name] + ' (' + column_name + ')' + ' to [' + @database_user_name + ']'
		from @database_permissions
		where	class_desc = 'OBJECT_OR_COLUMN'
				and column_name is not NULL


		insert into @Result (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' on type::' + [object_name] + ' to [' + @database_user_name + ']'
		from @database_permissions
		where class_desc = 'TYPE'


		-- next database
		next_database:

		-- clean db user info
		delete from @user_info
		delete from @database_roles
		delete from @database_permissions

		-- next database
		fetch next from Database_Cursor
		into @database_name
		
	end

	close Database_Cursor
	deallocate Database_Cursor


	


-- show results
show_results:
select * from @Result



end				-- procedure logic end



