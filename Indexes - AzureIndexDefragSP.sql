

create or alter procedure AzureIndexDefragSP (	
	@TableSizeOver						int = 0,
	@TableSizeUnder						int = 1000000000,
	
	@ReorganizeThreshold				decimal(5,2) = 10,
	@RebuildThreshold					decimal(5,2) = 30,

	@RebuildOnly						bit = 0,
	@GenerateReportOnly					bit = 0
	--,@MaxDOP								tinyint = 2
)

as begin


/****************************************** Azure Index Defrag Procedure **********************************************************

This procedure is designed to work with Azure SQL Database
Procedure detects indexes that need either REBUILD or REORGANIZE defragmentation 



Author: Aleksey Vitsko
Created : July 2018

History:

2018-07-04 
Created procedure


**********************************************************************************************************/

set nocount on



/* TESTING

exec AzureIndexDefragSP
	@TableSizeOver = 10,
	@ReorganizeThreshold = 10,
	@RebuildThreshold = 30,
	@GenerateReportOnly = 1

*/


/* -- debug arguments
declare 
	@TableSizeOver						int = 10,
	@TableSizeUnder						int = 50,
	
	@ReorganizeThreshold				decimal(5,2) = 10,
	@RebuildThreshold					decimal(5,2) = 30,
	@GenerateReportOnly					bit = 1
	--,@MaxDOP								tinyint = 16
*/






----------------------------------------- Pre-Checks ------------------------------------------------------

-- table size limits
if @tableSizeOver > @tableSizeUnder begin
	print 'LOWER table size limit can not be higher then the UPPER size limit'
	return
end

-- reogranize vs rebuild thresholds
if @ReorganizeThreshold > @RebuildThreshold begin
	print 'REORGANIZE threshold should not be higher than REBUILD threshold'
	return
end



---------------------------------------- Create Temp Worksets --------------------------------------------


if object_id('tempdb..#Tables') is not null begin drop table #Tables end

create table #Tables (
	ID						int identity (1,1),
	ObjectID				int primary key,
	TableName				varchar(100),
	
	SchemaID				int,
	SchemaName				varchar(30),

	TableNameWithSchema		varchar(100),
	
	TotalSizeMB				decimal(16,2))
	


if object_id('tempdb..#TableSizesMB') is not null begin drop table #TableSizesMB end

create table #TableSizesMB (
	rID				int identity primary key,
	rName			varchar(100),
	
	rRows			bigint,
	rKBperRow		decimal(10,2),
	
	rReserved		varchar(50),
	
	rData			varchar(50),
	rIndex_Size		varchar(50),
	rUnused			varchar(50),
	
	rData2			bigint null,
	rIndex_Size2	bigint null,
	rUnused2		bigint null,			
	rTotalSize2		bigint null,

	rData3			decimal(16,2) null,
	rIndex_Size3	decimal(16,2) null,
	rUnused3		decimal(16,2) null,
	rTotalSize3		decimal(16,2) null)


if object_id('tempdb..#IndexPhysicalStats') is not null begin drop table #IndexPhysicalStats end

create table #IndexPhysicalStats (
	ipsID							int identity primary key,
	ipsTableName					varchar(100),
	IndexName					varchar(100),
	IndexTypeDesc					varchar(50),			

	IndexDepth						tinyint,
	SizeMB							int,
	[PageCount]						int,
	FragmentCount					int,
	AvgFragmentationPct				decimal(5,2),
	AvgFragmentSizeInPages			decimal(5,2),
	
	Command							varchar(15),
	ActionStatement					varchar(200)
)





---------------------------------------- Get Table Sizes --------------------------------------------


-- get table list for current database
insert into #Tables (TableName, ObjectID, SchemaID)
select 
	[name],
	[object_id],
	[schema_id]
from sys.tables
order by name


-- get schema names
update #Tables
	set SchemaName = [name]
from #Tables
	join sys.schemas on
		SchemaID = [schema_id]


-- full table names
update #Tables
	set TableNameWithSchema = SchemaName + '.' + TableName



-- cycle
declare @counter int = 1
declare @name varchar(100)

while @counter <= (select count(*) from #Tables) begin
	select @name = TableNameWithSchema from #Tables where ID = @counter

	insert into #TableSizesMB (rName, rRows, rReserved, rData, rIndex_Size, rUnused)
	exec sp_spaceused @name

	set @counter += 1
end



-- get integer size values in KB
Update #TableSizesMB
	set rData2 = cast(substring(rData,1,charindex(' KB',rData)) as bigint),
		rIndex_Size2 = cast(substring(rIndex_Size,1,charindex(' KB',rIndex_Size)) as bigint),
		rUnused2 = cast(substring(rUnused,1,charindex(' KB',rUnused)) as bigint)

update #TableSizesMB
	set rTotalSize2 = rData2 + rIndex_Size2 + rUnused2


-- calculate size in MB
Update #TableSizesMB
	set rData3 = cast(rData2 as decimal(16,2)) / 1024,
		rIndex_Size3 = cast(rIndex_Size2 as decimal(16,2)) / 1024,
		rUnused3 = cast(rUnused2 as decimal(16,2)) / 1024,
		rTotalSize3 = cast(rTotalSize2 as decimal(16,2)) / 1024


-- table size to the main table
update #Tables
	set TotalSizeMB = rTotalSize3
from #Tables
	join #TableSizesMB on
		TableName = rName



-- delete tables smaller or larger then specified limits
delete from #Tables
where	TotalSizeMB < @TableSizeOver
		or TotalSizeMB > @TableSizeUnder



-- index physical stats
insert into #IndexPhysicalStats (ipsTableName, IndexName, IndexTypeDesc, IndexDepth, SizeMB, [PageCount], FragmentCount, AvgFragmentationPct, AvgFragmentSizeInPages)
select 
	t.TableName,
	i.name,
	physicalstats.index_type_desc,
	index_depth,
	page_count / 128	[size_MB],
	page_count,
	fragment_count,
	avg_fragmentation_in_percent,
	avg_fragment_size_in_pages
	
from #Tables t
	join sys.indexes i on
		ObjectID = i.[object_id]
	join sys.dm_db_index_physical_stats (db_id(),NULL,NULL,NULL,NULL) physicalstats on
		physicalstats.database_id = db_id()
		and i.[object_id] = physicalstats.[object_id]
		and i.[index_id] = physicalstats.[index_id]
order by TableName, avg_fragmentation_in_percent




-- remove indexes with low level of fragmentation
delete from #IndexPhysicalStats
where AvgFragmentationPct < @ReorganizeThreshold



-- command
update #IndexPhysicalStats
	set Command = 'REORGANIZE'
where	AvgFragmentationPct >= @ReorganizeThreshold
		and AvgFragmentationPct < @RebuildThreshold
		and IndexTypeDesc in ('CLUSTERED INDEX','NONCLUSTERED INDEX')

update #IndexPhysicalStats
	set Command = 'REBUILD'
where	AvgFragmentationPct >= @RebuildThreshold
		or IndexTypeDesc in ('HEAP')


-- action statement
update #IndexPhysicalStats
	set ActionStatement = 'alter index ' + quotename(IndexName) + ' on ' + quotename(ipsTableName) + ' REORGANIZE'
where Command = 'REORGANIZE'

update #IndexPhysicalStats
	set ActionStatement = 'alter index ' + quotename(IndexName) + ' on ' + quotename(ipsTableName) + ' REBUILD with (ONLINE=ON)'
where	Command = 'REBUILD'
		and IndexTypeDesc in ('CLUSTERED INDEX','NONCLUSTERED INDEX')


update #IndexPhysicalStats
	set ActionStatement = 'alter table ' + quotename(ipsTableName) + ' REBUILD with (ONLINE=ON)'
where	Command = 'REBUILD'
		and IndexTypeDesc in ('HEAP')


-- generate report only 
if @GenerateReportOnly = 1 begin
	select * from #IndexPhysicalStats
end





---------------------------------------- Perform Operations --------------------------------------------


if @GenerateReportOnly = 0 begin

declare @ActionStatement varchar(500)


-- reorganize indexes 
if @RebuildOnly = 0 begin

	declare IndexReorganize cursor local fast_forward for
	select ActionStatement
	from #IndexPhysicalStats
	where Command = 'REORGANIZE'

	open IndexReorganize
	fetch next from IndexReorganize into @ActionStatement

	while @@FETCH_STATUS = 0 begin

		print 'Starting --> "' + @ActionStatement + '"...'

		-- execute command
		exec (@ActionStatement)

		print 'Completed "' + @ActionStatement + '"'
		print ''

		-- next command
		fetch next from IndexReorganize into @ActionStatement

	end		-- reorganize cursor end

	close IndexReorganize
	deallocate IndexReorganize

end			-- end of reorganize section




-- rebuild indexes
declare IndexRebuild cursor local fast_forward for
select ActionStatement
from #IndexPhysicalStats
where Command = 'REBUILD'

open IndexRebuild
fetch next from IndexRebuild into @ActionStatement

while @@FETCH_STATUS = 0 begin

	print 'Starting --> "' + @ActionStatement + '"...'

	-- execute command
	exec (@ActionStatement)

	print 'Completed "' + @ActionStatement + '"'
	print ''

	-- next command
	fetch next from IndexRebuild into @ActionStatement

end		-- rebuild cursor end

close IndexRebuild
deallocate IndexRebuild


end				-- perform operations end




end