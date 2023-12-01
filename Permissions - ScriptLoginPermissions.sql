


create or alter procedure ScriptLoginPermissions (@LoginName as varchar(150)) as begin

set nocount on


/********************************************************* SCRIPT LOGIN PERMISSIONS PROCEDURE *****************************************************

Author: Aleksey Vitsko

Version: 1.11

Description: scripts server-level and database-level (database, schema, object, column) permissions for specified login
Result can be copy-pasted and used to recreate these permissions on a different server. 
Also, SP can be used to simply check permissions for a login, to see what she can or cannot do with certain securables.


History:

--> 2023-12-01 - Aleksey Vitsko - use "sys.login_token" instead of "xp_logininfo" to resolve group membership
--> 2022-09-16 - Aleksey Vitsko - add square brackets to schema names and object names
--> 2022-09-15 - Aleksey Vitsko - replace "GRANT_WITH_GRANT_OPTION " by " WITH GRANT OPTION"
--> 2022-09-15 - Aleksey Vitsko - sort the database-level (database, schema, object, column) permissions
--> 2022-09-15 - Aleksey Vitsko - add schema names as a prefix to object names
--> 2020-01-06 - Aleksey Vitsko - even if login is sysadmin, still show all other permissions (were not shown before)
--> 2019-02-01 - Aleksey Vitsko - added support for master, msdb, model databases
--> 2019-02-01 - Aleksey Vitsko - look into ONLINE state databases only
--> 2018-12-05 - Aleksey Vitsko - fixed bug related to xp_logininfo sp and SQL logins
--> 2018-11-19 - Aleksey Vitsko - added support for Active Directory group login membership: show information about AD group memberships
--> 2018-11-19 - Aleksey Vitsko - added support for column level permissions
--> 2018-05-01 - Aleksey Vitsko - created procedure


*******************************************************************************************************************************************************/



-------------------------------------------------------------------- Variables  -----------------------------------------------------------------------

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
	[schema_name]			varchar(150),
	[object_name]			varchar(150),
	[permission_name]		varchar(150),
	state_desc				varchar(150),
	column_name				varchar(150))


declare @login_token table (
	tName					varchar(128), 
	tType					varchar(128),
	tUsage					varchar(128)

	primary key (tName, tType, tUsage)
	)


-- result table that will contain all statements
declare @Result table (
	SQLStatement			varchar(max))


declare @Result_temp table (
	SQLStatement			varchar(500) primary key)


	

-------------------------------------------------------------------- Main Logic  -----------------------------------------------------------------------

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



	-- login token
	begin try
	execute as login = @LoginName

		insert into @login_token (tName, tType, tUsage)
		select
			distinct [name], [type], usage
		from sys.login_token
		where	principal_id <> 0
				and [name] <> @LoginName
				and [type] <> 'SERVER ROLE'

	revert
	end try
	begin catch
		print ERROR_MESSAGE()
	end catch

	if (select count(*) from @login_token) > 0 begin

		insert into @Result (SQLStatement)
		select '-- Group membership:' 

		insert into @Result (SQLStatement)
		select '-- ' + quotename(@LoginName) + ' is a member of ' + lower(tType) + ': ' + quotename([tName]) --+ ' -- (' + lower(usage) + ')'
		from @login_token
		
		insert into @Result (SQLStatement)
		select ''

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
		select '-- !!! WARNING: [' + @LoginName + ']' + ' is a member of SYSADMIN server role'

		insert into @Result (SQLStatement)
		select '-- !!! WARNING: [' + @LoginName + ']' + ' can do everything on this instance, you can ignore below permissions'
						
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
				when ''OBJECT_OR_COLUMN'' then os.[name]
				when ''TYPE'' then type_schema.[name]
				else ''''
			end,
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
			left join ' + @database_name + '.sys.schemas os on
				o.schema_id = os.schema_id
			left join ' + @database_name + '.sys.schemas type_schema on
				t.schema_id = type_schema.schema_id
		where grantee_principal_id = ' + cast(@database_principal_id as varchar)
				

		insert into @database_permissions (class_desc,[schema_name],[object_name],[permission_name],state_desc,column_name)
		exec (@sql)

		
		-- insert database level permissions into result table
		insert into @Result_temp (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' to [' + @database_user_name + ']'
		from @database_permissions
		where class_desc = 'DATABASE'

		-- schema level permissions 
		insert into @Result_temp (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' on schema::[' + [object_name] + '] to [' + @database_user_name + ']'
		from @database_permissions
		where class_desc = 'SCHEMA'

		-- object level permissions
		insert into @Result_temp (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' on [' + [schema_name] + '].[' + [object_name] + '] to [' + @database_user_name + ']'
		from @database_permissions
		where	class_desc = 'OBJECT_OR_COLUMN'
				and column_name is NULL

		-- column level permissions
		insert into @Result_temp (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' on [' + [schema_name] + '].[' + [object_name] + '] ([' + column_name + '])' + ' to [' + @database_user_name + ']'
		from @database_permissions
		where	class_desc = 'OBJECT_OR_COLUMN'
				and column_name is not NULL

		-- permissions for types
		insert into @Result_temp (SQLStatement)
		select state_desc + ' ' + [permission_name] + ' on type::[' + [schema_name] + '].[' + [object_name] + '] to [' + @database_user_name + ']'
		from @database_permissions
		where class_desc = 'TYPE'



		-- replace "GRANT_WITH_GRANT_OPTION " by " WITH GRANT OPTION"
		update @Result_temp
			set SQLStatement = replace(SQLStatement,'GRANT_WITH_GRANT_OPTION','GRANT') + ' WITH GRANT OPTION'
		where SQLStatement like 'GRANT_WITH_GRANT_OPTION%'


		-- sort the permissions before inserting into @Result
		insert into @Result (SQLStatement)
		select SQLStatement 
		from @Result_temp
		order by SQLStatement




		-- next database
		next_database:

		-- clean db user info
		delete from @user_info
		delete from @database_roles
		delete from @database_permissions
		delete from @Result_temp


		-- next database
		fetch next from Database_Cursor
		into @database_name
		
	end

	close Database_Cursor
	deallocate Database_Cursor


	
-- show results
select * from @Result



end				-- procedure logic end



