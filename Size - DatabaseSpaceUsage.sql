

create or alter procedure DatabaseSpaceUsage (
	@Command varchar(50) = 'all') as 
	
begin

/****************************************************************** DATABASE SPACE USAGE PROCEDURE **************************************************************

Author: Aleksey Vitsko

Description: For a given database, shows: 
1) Total data / index / unused size inside the data file 
2) data / index / unused size for each table in a database

Version: 1.11

History:

2021-03-12 --> Aleksey Vitsko - added square brackets to schema names that have following format: 'domain\username'
2019-11-21 --> Aleksey Vitsko - added ability to log database size into table ServerLogsDB..[DatabaseGrowthLogger]
2019-11-20 --> Aleksey Vitsko - added "Total_Rows" column to "all" output
2019-11-18 --> Aleksey Vitsko - now @PercentUsed is calculated based on @TotalDatabaseUsedMB OR @AllocatedMB - whichever is greater
(found that in Azure SQL Database @AllocatedMB was very low compared to TotalDatabaseUsedMB)
2019-10-07 --> Aleksey Vitsko - replaced @detailed bit parameter by @Command varchar(50) parameter
(@Command supports several commands such as "all","summary","tables simple","tables detailed","log")
2019-10-07 --> Aleksey Vitsko - @PercentUsed is now calculated as @AllocatedMB (from sys.dm_db_file_space_usage) / @DBFileSize (total database size)
(before it was sum(data + index + unused table level) / DBFileSize)
2019-10-07 --> Aleksey Vitsko - replaced @tables and @rating by #Tables and #Rating
2018-07-02 --> Aleksey Vitsko - added @Detailed bit parameter
2018-06-27 --> Aleksey Vitsko - added database file size and pct used info
2018-06-26 --> Aleksey Vitsko - added multi-schema database support
2018-06-25 --> Aleksey Vitsko - added "Row_Count" column and "Kb_per_Row" calculation
2017-08-15 --> Aleksey Vitsko - created stored procedure

*****************************************************************************************************************************************************************/

set nocount on


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
	TableName				varchar(100),
	
	SchemaID				int,
	SchemaName				varchar(30),

	TableNameWithSchema		varchar(100))


create table #rating (
	rID						int identity primary key,
	rName					varchar(100),
	
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



-- get table list for current database
insert into #Tables (TableName, SchemaID)
select 
	[name],
	[schema_id]
from sys.tables
order by name


-- get schema names
update #Tables
	set SchemaName = [name]
from #Tables
	join sys.schemas on
		SchemaID = [schema_id]


-- add square brackets to schema names that have following format: 'domain\username'
update #Tables
	set SchemaName = quotename(SchemaName)
where SchemaName like '%\%'


-- full table names
update #Tables
	set TableNameWithSchema = SchemaName + '.' + TableName



-- cycle
declare @counter int = 1
declare @name varchar(100)

while @counter <= (select count(*) from #Tables) begin
	select @name = TableNameWithSchema from #Tables where ID = @counter

	insert into #Rating (rName, rRows, rReserved, rData, rIndex_Size, rUnused)
	exec sp_spaceused @name

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



-- megabytes per row
update #Rating
	set rKBperRow = cast(rTotalSize2 as decimal(16,2)) / rRows
where rRows > 0

update #Rating
	set rKBperRow = 0
where rRows = 0


-- database file size
declare 
	@DBFileSize int, 
	@TotalDatabaseUsedMB int,
	@AllocatedMB int,
	@PercentUsed decimal(5,2)

set @DBFileSize = (select sum(size) / 128 
					from sys.database_files
					where [type_desc] = 'ROWS')


set @AllocatedMB = (select sum(allocated_extent_page_count) / 128 
					from sys.dm_db_file_space_usage)


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
		db_name()								[Database],
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
	order by [Table_Total_MB], rName

end



-- show summary
if @Command = 'summary' begin

	-- show summary
	select 
		db_name()								[Database],
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



-- show simplified info
if @Command = 'table simple' begin

	-- show simple table info
	select
		rName					[TableName], 
		rRows					[Row_Count],
		round(rTotalSize3,2)	[Table_Total_MB]	

	from #Rating 
	order by [Table_Total_MB], rName

end



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
						where [Database_Name] = db_name())


	-- if database size was logged previously (if table has any records for given database)
	if @LastLogDate is not NULL begin
		
		select 
			@LastAllocatedMB = Database_Allocated_MB,
			@LastPercentUsed = Percent_Used
		from ServerLogsDB..[DatabaseGrowthLogger] 
		where	[Database_Name] = db_name()
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
		db_name(),								-- [Database_Name]

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

set nocount off

end