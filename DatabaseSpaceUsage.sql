

create or alter procedure DatabaseSpaceUsage (
	@DatabaseName			nvarchar(200)	= '',
	@Command				varchar(50)		= 'all'				-- "all" output mode by default
	
	) as begin

/****************************************************************** DATABASE SPACE USAGE PROCEDURE **************************************************************

Author: Aleksey Vitsko

Version: 1.18

Description: For a given database, shows: 
1) Total data / index / unused size inside the data file 
2) data / index / unused size for each table in a database

--------------------------------------------------------------------------

@Command parameter (output depends on supplied value):
'all'							- default value, shows summary for database + table level information
'summary'						- shows summary information
'tables simple'					- shows table-level information
'tables detail'					- shows detailed table-level information
'log'							- log summary info to a table (does not work at the moment, going to refactor this)

--------------------------------------------------------------------------

History:

2025-01-29 --> Aleksey Vitsko - when calling sp_spaceused, both table name and schema name should be taken in brackets
2023-12-05 --> Aleksey Vitsko - add square brackets for database names like "A.B.C" (issue https://github.com/aleksey-vitsko/Database-Administrator-Tools/issues/2 )
2022-11-30 --> Aleksey Vitsko - uncomment the logging part, corrections to make it work (full refactor yet to come) 
2022-09-19 --> Aleksey Vitsko - made "tables detail" command work
2022-09-19 --> Aleksey Vitsko - implement @DatabaseName parameter, and it's validation
2022-09-19 --> Aleksey Vitsko - comment out the logging part, will refactor it later
2022-09-19 --> Aleksey Vitsko - sort table details by [Table_Total_MB] descending
2022-09-19 --> Aleksey Vitsko - changed table and schema names from varchar to nvarchar, increased length  
2022-09-19 --> Aleksey Vitsko - always add square brackets to schema names
2021-03-12 --> Aleksey Vitsko - added square brackets to schema names that have following format: 'domain\username'
2019-11-21 --> Aleksey Vitsko - added ability to log database size into table ServerLogsDB..[DatabaseGrowthLogger]
2019-11-20 --> Aleksey Vitsko - added "Total_Rows" column to "all" output
2019-11-18 --> Aleksey Vitsko - now @PercentUsed is calculated based on @TotalDatabaseUsedMB OR @AllocatedMB - whichever is greater (found that in Azure SQL Database @AllocatedMB was very low compared to TotalDatabaseUsedMB)
2019-10-07 --> Aleksey Vitsko - replaced @detailed bit parameter by @Command varchar(50) parameter (@Command supports several commands such as "all","summary","tables simple","tables detailed","log")
2019-10-07 --> Aleksey Vitsko - @PercentUsed is now calculated as @AllocatedMB (from sys.dm_db_file_space_usage) / @DBFileSize (total database size) (before it was sum(data + index + unused table level) / DBFileSize)
2019-10-07 --> Aleksey Vitsko - replaced @tables and @rating by #Tables and #Rating
2018-07-02 --> Aleksey Vitsko - added @Detailed bit parameter
2018-06-27 --> Aleksey Vitsko - added database file size and pct used info
2018-06-26 --> Aleksey Vitsko - added multi-schema database support
2018-06-25 --> Aleksey Vitsko - added "Row_Count" column and "Kb_per_Row" calculation
2017-08-15 --> Aleksey Vitsko - created stored procedure

*****************************************************************************************************************************************************************/

set nocount on


-- variables
declare 
	@EngineEdition		varchar(300) = cast(serverproperty('EngineEdition') as varchar(300)),
	@SQL				nvarchar(1000) = ''



-- @DatabaseName parameter validation
if @EngineEdition = '5' and @DatabaseName <> '' begin
	
	print 'Do not specify @DatabaseName parameter value when running procedure in Azure SQL Database
Exiting...'

	return
end

-- fill empty database name by current database name
if @DatabaseName = '' begin
	
	set @DatabaseName = db_name()

end

-- check if supplied @DatabaseName exists in sys.databases
if not exists (select * from sys.databases where [name] = @DatabaseName) begin

	print 'Supplied @DatabaseName value doesn''t exist in sys.databases
Please specify name of existing database

Exiting...'

	return
end
	



-- @Command parameter validation
if @Command not in ('all','summary','tables simple','tables detail','log') begin
	
	print '
Supplied @Command value is not supported!

Supported commands list:

"all"
"summary"
"tables simple"
"tables detail"
"log"
'

	return
end


-- temp tables
create table #Tables  (
	ID						int identity (1,1),
	TableName				nvarchar(500),
	
	SchemaID				int,
	SchemaName				nvarchar(100),

	TableNameWithSchema		nvarchar(600))


create table #rating (
	rID						int identity primary key,
	rName					nvarchar(100),
	
	rRows					bigint,
	rKBperRow				decimal(10,2),
	
	rReserved				varchar(50),
	
	rData					varchar(50),
	rIndex_Size				varchar(50),
	rUnused					varchar(50),
	
	rData2					bigint null,
	rIndex_Size2			bigint null,
	rUnused2				bigint null,			
	rTotalSize2				bigint null,

	rData3					decimal(16,2) null,
	rIndex_Size3			decimal(16,2) null,
	rUnused3				decimal(16,2) null,
	rTotalSize3				decimal(16,2) null)



-- get list of tables for current database
set @SQL = 'select 
	quotename([name]),
	[schema_id]
from ' + quotename(@DatabaseName) + '.sys.tables
order by name'

insert into #Tables (TableName, SchemaID)
exec (@SQL)


-- get schema names
set @SQL = 'update #Tables
	set SchemaName = [name]
from #Tables
	join ' + quotename(@DatabaseName) + '.sys.schemas on
		SchemaID = [schema_id]'

exec (@SQL)


-- add square brackets to schema names 
update #Tables
	set SchemaName = quotename(SchemaName)


-- table names with schema names
update #Tables
	set TableNameWithSchema = SchemaName + '.' + TableName



-- cycle
declare @counter int = 1
declare @name nvarchar(600)

while @counter <= (select count(*) from #Tables) begin
	
	select @name = TableNameWithSchema from #Tables where ID = @counter

	set @SQL = 'exec ' + quotename(@DatabaseName) + '..sp_spaceused @_name'

	insert into #Rating (rName, rRows, rReserved, rData, rIndex_Size, rUnused)
	exec sp_executesql @stmt = @SQL, @params = N'@_name nvarchar(600)', @_name = @name

	set @counter += 1

end



-- get integer size values in KB
Update #Rating
	set rData2 = cast(substring(rData,1,charindex(' KB',rData)) as bigint),
		rIndex_Size2 = cast(substring(rIndex_Size,1,charindex(' KB',rIndex_Size)) as bigint),
		rUnused2 = cast(substring(rUnused,1,charindex(' KB',rUnused)) as bigint)

update #Rating
	set rTotalSize2 = rData2 + rIndex_Size2 + rUnused2


-- calculate size in MB
Update #Rating
	set rData3 = cast(rData2 as decimal(16,2)) / 1024,
		rIndex_Size3 = cast(rIndex_Size2 as decimal(16,2)) / 1024,
		rUnused3 = cast(rUnused2 as decimal(16,2)) / 1024,
		rTotalSize3 = cast(rTotalSize2 as decimal(16,2)) / 1024



-- kilobytes per row
update #Rating
	set rKBperRow = cast(rTotalSize2 as decimal(16,2)) / rRows
where rRows > 0

update #Rating
	set rKBperRow = 0
where rRows = 0


-- database file size
declare 
	@DBFileSize				int, 
	@TotalDatabaseUsedMB	int,
	@AllocatedMB			int,
	@PercentUsed			decimal(5,2)


create table #DBFileSpace (
	DBFileSize				int,
	AllocatedMB				int)


set @SQL = 'select sum(size) / 128 
					from ' + quotename(@DatabaseName) + '.sys.database_files
					where [type_desc] = ''ROWS'''


insert into #DBFileSpace (DBFileSize)
exec (@SQL)


set @SQL = 'select sum(allocated_extent_page_count) / 128 
					from ' + quotename(@DatabaseName) + '.sys.dm_db_file_space_usage'


insert into #DBFileSpace (AllocatedMB)
exec (@SQL)


set @DBFileSize = (select DBFileSize from #DBFileSpace where DBFileSize is not NULL)
set @AllocatedMB = (select AllocatedMB from #DBFileSpace where AllocatedMB is not NULL)


set @TotalDatabaseUsedMB = (select sum(rTotalSize3) from #Rating)



if @TotalDatabaseUsedMB > @AllocatedMB begin
	set @PercentUsed = cast(@TotalDatabaseUsedMB as decimal(16,2)) / cast(@DBFileSize as decimal(16,2)) * 100
end

if @AllocatedMB > @TotalDatabaseUsedMB begin
	set @PercentUsed = cast(@AllocatedMB as decimal(16,2)) / cast(@DBFileSize as decimal(16,2)) * 100
end




--------------------------------------------------------------- Show Data ----------------------------------------------------------------

-- show all
if @Command = 'all' begin

	-- show summary
	select 
		@DatabaseName							[Database],
		count(*)								[Table_Count],
		sum(rRows)								[Total_Rows],
		sum(rData3)								[Database_Data_MB],
		sum(rIndex_Size3)						[Database_Index_MB],
		sum(rUnused3)							[Database_Unused_MB],
		sum(rTotalSize3)						[Total_Database_Used_MB],
		@AllocatedMB							[Total_Database_Allocated_MB],
		@DBFileSize								[Database_File_Size_MB],
		cast(@PercentUsed as varchar) + ' %'	[Percent_Used]
	from #Rating


	-- show table details
	select 
		rName					[Table_Name], 
		rRows					[Row_Count],
		rKBperRow				[Kb_Per_Row],
		''						[ - Blank - ],
		round(rData3,2)			[Table_Data_MB],
		round(rIndex_Size3,2)	[Table_Index_MB],
		round(rUnused3,2)		[Table_Unused_MB],
		round(rTotalSize3,2)	[Table_Total_MB]	

	from #Rating 
	order by [Table_Total_MB] desc, rName

end



-- show summary
if @Command = 'summary' begin

	-- show summary
	select 
		@DatabaseName							[Database],
		count(*)								[Table_Count],
		sum(rData3)								[Database_Data_MB],
		sum(rIndex_Size3)						[Database_Index_MB],
		sum(rUnused3)							[Database_Unused_MB],
		sum(rTotalSize3)						[Total_Database_Used_MB],
		@AllocatedMB							[Total_Database_Allocated_MB],
		@DBFileSize								[Database_File_Size_MB],
		cast(@PercentUsed as varchar) + ' %'	[Percent_Used]
	from #Rating

end



-- show simple table info
if @Command = 'tables simple' begin

	select
		rName					[TableName], 
		rRows					[Row_Count],
		round(rTotalSize3,2)	[Table_Total_MB]	

	from #Rating 
	order by [Table_Total_MB] desc, rName

end



-- show table details
if @Command = 'tables detail' begin
		
	select 
		rName					[Table_Name], 
		rRows					[Row_Count],
		rKBperRow				[Kb_Per_Row],
		''						[ - Blank - ],
		round(rData3,2)			[Table_Data_MB],
		round(rIndex_Size3,2)	[Table_Index_MB],
		round(rUnused3,2)		[Table_Unused_MB],
		round(rTotalSize3,2)	[Table_Total_MB]	

	from #Rating 
	order by [Table_Total_MB] desc, rName

end



/*
-- log DB size to table
if @Command = 'log' begin

	declare 
		@LastLogDate		smalldatetime,
		@LastAllocatedMB	int,
		@LastPercentUsed	decimal(5,2),
		
		@HoursDiff			smallint = 0,
		@AllocatedDelta		int = 0,
		@PercentDelta		decimal(5,2) = 0


	set @LastLogDate = (select max(Date_Full) 
						from ServerLogsDB..[DatabaseGrowthLogger] 
						where [Database_Name] = @DatabaseName)


	-- if database size was logged previously (if table has any records for given database)
	if @LastLogDate is not NULL begin
		
		select 
			@LastAllocatedMB = Database_Allocated_MB,
			@LastPercentUsed = Percent_Used
		from ServerLogsDB..[DatabaseGrowthLogger] 
		where	[Database_Name] = @DatabaseName
				and Date_Full = @LastLogDate

		set @HoursDiff = datediff(hour,@LastLogDate,getdate())
		set @AllocatedDelta = @AllocatedMB - @LastAllocatedMB
		set @PercentDelta = @PercentUsed - @LastPercentUsed

	end

	
	-- add record to logging table
	insert into ServerLogsDB..[DatabaseGrowthLogger] (
		Server_Name,
		[Database_Name],
		
		Date_Full,
		Day_Of_Week,
		Log_Date,
		Log_Hour,
		
		Table_Count,
		Total_Rows,
		
		Database_Data_MB,
		Database_Index_MB,
		Database_Unused_MB,
		Database_Allocated_MB,
		Database_File_Size_MB,
		Percent_Used,
		
		Hours_Diff,
		Database_Allocated_Delta,
		Percent_Used_Delta)
	select 
		@@ServerName,							-- Server_Name
		@DatabaseName,							-- [Database_Name]

		getdate(),								-- Date_Full
		datepart(dw,getdate()),					-- Day_Of_Week
		cast(getdate() as date),				-- Log_Date
		datepart(hour,getdate()),				-- Log_Hour

		count(*),								-- Table_Count
		sum(rRows),								-- Total_Rows
		
		sum(rData3),							-- Database_Data_MB
		sum(rIndex_Size3),						-- Database_Index_MB
		sum(rUnused3),							-- Database_Unused_MB
		@AllocatedMB,							-- Database_Allocated_MB
		@DBFileSize,							-- Database_File_Size_MB
		@PercentUsed,							-- Percent_Used

		@HoursDiff,								-- Hours_Diff
		@AllocatedDelta,						-- Database_Allocated_Delta
		@PercentDelta							-- Percent_Used_Delta
	from #Rating


	

end 
*/
set nocount off

end


