

create or alter procedure IdentityRunOutChecker (
	@DatabaseName				nvarchar(128) = 'all',			/* by default, looks into all USER databases on a server */
	@PercentUsedOver			tinyint	= 70					/* show only identity columns that are "filled" more than specified percent */
	)
as begin

/******************************************************** IDENTITY RUN OUT CHECKER PROCEDURE ********************************************************

Author: Aleksey Vitsko

Version: 1.01


Description: 

Finds tables with identity columns (of tinyint, smallint, int, bigint types) on your server, 
and checks how close they are to exhaust their data types limits.

Use this SP to peform a check on your server, 
to avoid situation where some of core production tables run out of possible integer values on a "one fine day".


Note:

Usually performs fast, as most (I hope :D) identity columns = primary keys = clustered indexes.
Can be slower if there are non-indexed identity column(s), getting max(ID) value from these may be slow (depending on number of rows).


History:

2025-08-20 -> Aleksey Vitsko - increase compatibility with Azure SQL Database
2025-08-18 -> Aleksey Vitsko - created procedure (1st version)


Tested on:

- SQL Server 2016, 2017, 2019, 2022, 2025 (CTP)
- Azure SQL Managed Instance (SQL 2022 update policy)
- Azure SQL Database


***************************************************************************************************************************************/

set nocount on

/* variables */
declare 
	@Query				nvarchar(max),
	@EngineEdition		int,
	@ID					int



/********************************************* Pre-checks and Validations ***************************************************************/

/* get the engine edition */
set @EngineEdition = (select cast(serverproperty('EngineEdition') as int))


/* in case of Azure SQL Database */
/* set the @DatabaseName parameter to the name of currently selected database */
if @EngineEdition = 5 and @DatabaseName = 'all' begin
	set @DatabaseName = db_name()
end
	

/* check if specified database name exists at sys.databases */
if @DatabaseName <> ('all') and not exists (select * from sys.databases where [name] = @DatabaseName) begin
		print 'Specified database [' + @DatabaseName + '] does not exist!'
		print 'Please specify database that exists at sys.databases.'
		print 'Exiting...'
		return
end


/* in case of Azure SQL Database */
/* querying master database from the context of user database is not allowed */
if @EngineEdition = 5 and @DatabaseName = 'master' and (select db_name()) <> 'master' begin
	print 'Specifying master database in SP from the context of current database is not allowed!'
		print 'Please specify currently selected database'
		print 'Exiting...'
		return
end


/* in case of Azure SQL Database */
/* querying user database from the context of master database is not allowed */
if @EngineEdition = 5 and @DatabaseName <> 'master'  and (select db_name()) = 'master' begin
	print 'Specifying a user database in SP from the context of master database is not allowed!'
		print 'Please specify currently selected database'
		print 'Exiting...'
		return
end
	

		
/********************************************* Temp Tables, Etc. ***************************************************************/

/* temp worksets */

drop table if exists #Databases
drop table if exists #TablesAndColumns 
drop table if exists #Current_Max_value


create table #TablesAndColumns (
	[ID]						int identity primary key,
	
	[Database_Name]				nvarchar(128),
	[Schema_Name]				nvarchar(128),
	[Table_Name]				nvarchar(128),
	[Column_Name]				nvarchar(128),
	[Column_Type]				nvarchar(128),
	
	[Current_Max_Value]			bigint,
	[Max_Possible_Value]		bigint,
	[Percent_Used]				decimal(5,2),

	[SQL_Statement]				nvarchar(max)
	)


create table #Databases (
	ID						int primary key identity,
	[Database_Name]			nvarchar(128)
	)


create table #Current_Max_value (
	Temp_Value		bigint
	)



/********************************************* Main Logic ***************************************************************/

/* for Azure SQL Database */
if @EngineEdition = 5 begin

	set @Query = 'select
		''' + @DatabaseName + '''		[Database_Name],
		s.[name]						[Schema_Name],
		t.[name]						[Table_Name],
		c.[name]						[Column_Name],
		types_dmv.[name]				[Column_Type]

	from sys.tables t
	
		join sys.schemas s on
			t.[schema_id] = s.[schema_id]

		join sys.columns c on
			t.[object_id] = c.[object_id]
			and is_identity = 1

		join sys.types types_dmv on 
			c.system_type_id = types_dmv.system_type_id
			and types_dmv.[name] in (''tinyint'',''smallint'',''int'',''bigint'')

	order by [Schema_Name], [Table_Name]'

	--print @Query


	/* execute the query */
	insert into #TablesAndColumns ([Database_Name], [Schema_Name], Table_Name, Column_Name, Column_Type)
	exec (@Query)

end



/* for SQL Server, Azure SQL Managed Instance etc. (not Azure SQL DB) */
if @EngineEdition <> 5 begin

	/* get all databases list */
	if @DatabaseName = 'all' begin
	
		insert into #Databases ([Database_Name])
			select [name]
			from sys.databases 
			where [name] not in ('master','msdb','model','tempdb')
			order by [name]

	end


	/* or, get just the selected database */
	if @DatabaseName <> 'all' begin

		insert into #Databases ([Database_Name])
			select @DatabaseName

	end


	/* cycle through list of databases */
	set @ID = 1

	while @ID <= (select max(ID) from #Databases) begin

		set @DatabaseName = (select [Database_Name] from #Databases where ID = @ID)

		/* create a query */
		set @Query = 'select
			''' + @DatabaseName + '''		[Database_Name],
			s.[name]						[Schema_Name],
			t.[name]						[Table_Name],
			c.[name]						[Column_Name],
			types_dmv.[name]				[Column_Type]

		from ' + @DatabaseName + '.sys.tables t
	
			join ' + @DatabaseName + '.sys.schemas s on
				t.[schema_id] = s.[schema_id]

			join ' + @DatabaseName + '.sys.columns c on
				t.[object_id] = c.[object_id]
				and is_identity = 1

			join ' + @DatabaseName + '.sys.types types_dmv on 
				c.system_type_id = types_dmv.system_type_id
				and types_dmv.[name] in (''tinyint'',''smallint'',''int'',''bigint'')

		order by [Schema_Name], [Table_Name]'

		--print @Query


		/* execute the query */
		insert into #TablesAndColumns ([Database_Name], [Schema_Name], Table_Name, Column_Name, Column_Type)
		exec (@Query)

		set @ID = @ID + 1

	end			

end



/* maximum allowed values for integer types */
update #TablesAndColumns
	set Max_Possible_Value = 
			case Column_Type
				when 'tinyint' then 255
				when 'smallint' then 32767
				when 'int' then 2147483647
				when 'bigint' then 9223372036854775807
			end
from #TablesAndColumns


/* generate SQL statements to execute to get current max values */

update #TablesAndColumns 
	set SQL_Statement = 'select max(' + quotename(Column_Name) + ') from ' + quotename([Database_Name]) + '.' + quotename([Schema_Name]) + '.' + quotename(Table_Name)




/* execute SQL statements one by one to get current max values */

set @ID = 1

while @ID <= (select max(ID) from #TablesAndColumns) begin
	
	set @Query = (select SQL_Statement from #TablesAndColumns where ID = @ID)

	raiserror (@Query,0,1) with nowait

	insert into #Current_Max_value (Temp_Value)
	exec (@Query)

	update top(1) #TablesAndColumns
		set Current_Max_Value = (select top(1) Temp_Value from #Current_Max_value)
	from #TablesAndColumns
	where ID = @ID 

	delete from #Current_Max_value

	set @ID = @ID + 1

end



/* handle empty tables */
update #TablesAndColumns
	set Current_Max_Value = 0
where	Current_Max_Value is NULL


/* calculate percentage */
update #TablesAndColumns
	set Percent_Used = (cast(Current_Max_Value as decimal(30,2)) / cast(Max_Possible_Value as decimal(30,2))) * 100
	

/* show data */
select
	cast(getdate() as smalldatetime)		[Date_Time],
	[Database_Name],
	[Schema_Name],
	Table_Name,
	Column_Name,
	Column_Type,
	Current_Max_Value,
	Max_Possible_Value,
	Percent_Used
from #TablesAndColumns
where Percent_Used >= @PercentUsedOver
order by [Database_Name], Percent_Used desc, Table_Name


end



/*


exec IdentityRunOutChecker @PercentUsedOver = 50


exec IdentityRunOutChecker 'TestDB', 0


*/

