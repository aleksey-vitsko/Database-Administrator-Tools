
-- use [master]

create or alter procedure IndexDefragSP (
	@TableSizeOver						int = 0,
	@TableSizeUnder						int = 1000000000,
	
	@ReorganizeThreshold				decimal(5,2) = 10,
	@RebuildThreshold					decimal(5,2) = 30,
	
	@TargetDB							varchar(250) = 'user',						-- list of databases where indexes will be evaluated (options: "all"; "user"; "system"; "even/odd")
																					-- or a user-specified list of databases comma/semicolon/space-separated ("database1, database2")
	
	@ExcludeDBList						varchar(250) = NULL,						-- exclude database list (example: "database1, database2") 
																					-- can be used in conjunction with @TargetDB = 'user' when you want to check all user databases, but exclude couple of them
	
	@ReorganizeOnly						bit = 0,
	@RebuildOnly						bit = 0,
	
	@RebuildHeapTables					bit = 0,
	@DoNotRebuildIndexOver_MB			int = 0,									-- do not rebuild indexes that are bigger than N megabytes in size (if you do not want to mess with big indexes)
	@MaxDOP								tinyint = 0,								-- max degree of paralellism

	@GenerateReportOnly					bit = 0,									

	@SendReportEmail					bit = 1,
	@EmailProfileName					varchar(100) = 'Server email alerts',
	@toList								varchar(500) = 'email@domain.com'

) 			

as begin
set nocount on

/****************************************** INFO **********************************************************

Author: Aleksey Vitsko
Created: December 2017

Version: 1.04

History:

2020-05-10 - Aleksey Vitsko
@TargetDB will be now 'user' by default, which means procedure will evaluate indexes in all user databases
@MaxDOP will not be 0 by default 

2020-05-10 - Aleksey Vitsko
Added @DoNotRebuildIndexOver_MB parameter
If size (megabytes) of the index that requires REBUILD, exceeds specified value (@DoNotRebuildIndexOver_MB, default = 0 (no limit)) - it will be ignored and will NOT be rebuilt
This way we can avoid rebuilding some really big indexes, and its consequences (possible data/log file growth, excessive transaction log backups, lots of IO in Availability Groups, etc)

2020-04-26 - Aleksey Vitsko
When @GenerateReportOnly = 1, report will show additional column - Index Size in Megabytes (IndexSizeMB)

2018-11-09 - Aleksey Vitsko
update/fix: Added support for databases that have tables in schemas that are not dbo



**********************************************************************************************************/

/*
 -- debug arguments
declare 
	@TableSizeOver						int = 10,
	@TableSizeUnder						int = 50,
	
	@ReorganizeThreshold				decimal(5,2) = 10,
	@RebuildThreshold					decimal(5,2) = 30,
	
	@TargetDB							varchar(250) = 'Database1',
	@ExcludeDBList						varchar(250) = NULL,
	@TargetTables						varchar(250) = NULL,

	@ReorganizeOnly						bit = 0,
	@RebuildOnly						bit = 0,
	@RebuildHeapTables					bit = 1,
	@GenerateReportOnly					bit = 1,
	@MaxDOP								tinyint = 16,
	@SendReportEmail					bit = 1,

	@EmailProfileName					varchar(100) = 'Server email alerts',
	@toList								varchar(500) = 'email@domain.com'
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

-- only one option allowed at a time
if @RebuildOnly = 1 and @ReorganizeOnly = 1 begin
	print 'Only one option (@RebuildOnly or @ReorganizeOnly) can be set to 1 at a time'
	return
end


-- don't send email for generate report only
if @GenerateReportOnly = 1 begin
	set @SendReportEmail = 0
end




----------------------------------------- Used Variables -------------------------------------------------

declare
	@DBname							varchar(150), 
	@DB_ID							int,
	@TableName						varchar(100),
	@IndexName						varchar(100),
	@iID							int	,
	@Type							varchar(15),

	-- execute statements
	@GetTables						varchar(max), 
	@GetSpaceUsed					varchar(max),
	@GetIndexes						varchar(max),
	@ActionStatement				varchar(500),
	@Action							varchar(10),

	-- measure time
	@Start							datetime,
	@End							datetime,
	@Diff							int,
	@ProgressText					varchar(500),

	@GlobalStart					datetime,
	@GlobalEnd						datetime,

	-- physical stats
	@TableTotalSize					decimal(16,2),

	@FragmentationPctBefore			decimal(5,2),
	@FragmentationPctAfter			decimal(5,2),

	@FragmentCountBefore			bigint,
	@FragmentCountAfter				bigint,

	@PageCountBefore				bigint,
	@PageCountAfter					bigint,

	@SizeBeforeMB					decimal(16,2),
	@SizeAfterMB					decimal(16,2),
	
	@ReducedBy						decimal(16,2),
	@ReductionPct					decimal(5,2),

	@Success						bit,
	@Error							bit,
	@ErrorMessage					varchar(500),
	@TimeSpentOnOperation			varchar(10),

	-- email repor body message
	@SubjectText					varchar(200),
	@msg							varchar(max) = ''


----------------------------------------- Target DB ------------------------------------------------------

-- progress messages
set @GlobalStart = getdate()
set @Start = getdate()


-- database list
declare @databases table (
	DBName				varchar(150),
	dDB_ID				int,
	
	DBSizeMB_Before		decimal(16,2),
	DBSizeMB_After		decimal(16,2),

	ReducedBy			decimal(16,2),
	ReductionPct		decimal(5,2))


-- all
if @TargetDB = 'all' begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] not in ('tempdb')
			and state_desc = 'ONLINE'
end

-- user
if @TargetDB in ('user','userdb') begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] not in ('tempdb','master','model','msdb')
			and state_desc = 'ONLINE'
end

-- system
if @TargetDB in ('system','systemdb') begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] in ('master','model','msdb')
			and state_desc = 'ONLINE'
end

-- even
if @TargetDB in ('even','evendb') begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] not in ('tempdb','master','model','msdb')
			and database_id % 2 = 0
			and state_desc = 'ONLINE'
end

-- odd
if @TargetDB in ('odd','odddb') begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] not in ('tempdb','master','model','msdb')
			and database_id % 2 = 1
			and state_desc = 'ONLINE'
end


-- specific db
if @TargetDB not in ('all','user','userdb','system','systemdb','even','evendb','odd','odddb') and exists (select * from sys.databases where [name] = @TargetDB) begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] = @TargetDB
			and state_desc = 'ONLINE'
end



-- list of DBs
if @TargetDB like '%,%' or @TargetDB like '% %' or @TargetDB like '%;%' begin
	
	declare @Increment tinyint = 0, @StringLength tinyint, @char varchar(1), @DBNameToInsert varchar(50)

	set @Increment = 1	
	set @StringLength = len(@TargetDB)
	set @DBNameToInsert = ''

	while @Increment <= @StringLength begin

		set @char = substring(@TargetDB,@Increment,1)

		if @char not in (' ',',',';') begin
			set @DBNameToInsert = @DBNameToInsert + @char
		end

		if @char in (' ',',',';') begin
			if exists (select * from sys.databases where [name] = @DBNameToInsert and state_desc = 'ONLINE') and not exists (select * from @databases where DBName = @DBNameToInsert) begin 
				insert into @databases (DBName)
				select @DBNameToInsert
			end	

			set @DBNameToInsert = ''
		end

		if @Increment = @StringLength begin
			if exists (select * from sys.databases where [name] = @DBNameToInsert and state_desc = 'ONLINE') and not exists (select * from @databases where DBName = @DBNameToInsert) begin 
				insert into @databases (DBName)
				select @DBNameToInsert
			end	
		end

		set @Increment = @Increment + 1
	
	end

end


-- DBs to exclude
if @ExcludeDBList is not NULL begin

	declare @DatabasesExclude table (
		DBNameExclude			varchar(150))
	
	declare @Increment2 tinyint = 0, @StringLengthEx tinyint, @char2 varchar(1), @DBNameToExclude varchar(50)

	set @Increment2 = 1	
	set @StringLengthEx = len(@ExcludeDBList)
	set @DBNameToExclude = ''

	while @Increment2 <= @StringLengthEx begin

		set @char2 = substring(@ExcludeDBList,@Increment2,1)

		if @char2 not in (' ',',',';') begin
			set @DBNameToExclude = @DBNameToExclude + @char2
		end

		if @char2 in (' ',',',';') begin
			if exists (select * from sys.databases where [name] = @DBNameToExclude and state_desc = 'ONLINE') and not exists (select * from @DatabasesExclude where DBNameExclude = @DBNameToExclude) begin 
				insert into @DatabasesExclude (DBNameExclude)
				select @DBNameToExclude
			end	

			set @DBNameToExclude = ''
		end

		if @Increment2 = @StringLengthEx begin
			if exists (select * from sys.databases where [name] = @DBNameToExclude and state_desc = 'ONLINE') and not exists (select * from @DatabasesExclude where DBNameExclude = @DBNameToExclude) begin 
				insert into @DatabasesExclude (DBNameExclude)
				select @DBNameToExclude
			end	
		end

		set @Increment2 = @Increment2 + 1
	
	end

	delete d
	from @databases d
		join @DatabasesExclude on
			dbName = DBNameExclude

end


-- get database id
update @Databases
	set dDB_ID = database_id
from @Databases
	join sys.databases on
		DBName = [name]



-- progress messages
set @End = getdate()
set @Diff = datediff(second,@Start,@End)

set @ProgressText = 'Getting Target DB List - ' + cast(@Diff as varchar) + ' sec
	'
RAISERROR ( @ProgressText, 0, 1 ) WITH NOWAIT; 





---------------------------------------- Create Temp Worksets --------------------------------------------

-- tables list
if object_id('tempdb..#Tables') is not null begin drop table #Tables end

create table #Tables (
	ID				int identity (1,1),
	tObject_ID		bigint,
	tTableName		varchar(100))


-- table size list
if object_id('tempdb..#TableSizesMB') is not null begin drop table #TableSizesMB end

create table #TableSizesMB (
	tsID					int identity primary key,
	
	tsDBName				varchar(100),	
	tsTableName				varchar(100),
	tsObject_ID				bigint,
	
	tsRows					bigint,
	
	tsReserved				varchar(50),
	tsData					varchar(50),
	tsIndex_Size			varchar(50),
	tsUnused				varchar(50),
	
	tsData_Size_KB			bigint null,
	tsIndex_Size_KB			bigint null,
	tsUnused_Size_KB		bigint null,			
	tsTotal_Size_KB			bigint null,

	tsData_Size_MB			decimal(16,2) null,
	tsIndex_Size_MB			decimal(16,2) null,
	tsUnused_Size_MB		decimal(16,2) null,
	tsTotal_Size_MB			decimal(16,2) null)



-- index table
if object_id('tempdb..#Indexes') is not null begin drop table #Indexes end

create table #Indexes (
	iID							int primary key identity,
	iDBName						varchar(100),
	iDB_ID						int,

	iTableSchemaName			varchar(100),
	--iTableSchema_ID				int,
	iTableName					varchar(100),
	iObject_ID					int,

	iTableIndexSizeBefore		decimal(16,2),
	iTableIndexSizeAfter		decimal(16,2),

	iTableTotalSizeBefore		decimal(16,2),
	iTableTotalSizeAfter		decimal(16,2),	
	
	iTableSizeReducedBy			decimal(16,2),
	iTableSizeReductionPct		decimal(5,2),

	iIndexName					varchar(128) default '',
	iIndex_ID					int,
	iType						varchar(60),
	
	iStatement					varchar(700),
	iAction						varchar(10),

	iFragmentCountBefore		int,
	iFragmentCountAfter			int,
	
	iFragmentationPctBefore		decimal(5,2),
	iFragmentationPctAfter		decimal(5,2),

	iPageCountBefore			int,
	iPageCountAfter				int,

	iIndexSizeMBBefore			decimal(16,2),
	iIndexSizeMBAfter			decimal(16,2),

	iSuccess					bit default 0,
	iStartTime					datetime,
	iEndTime					datetime,

	iError						bit default 0,
	iErrorMessage				varchar(250),

	iHours						int,
	iMinutes					int,
	iSeconds					int,

	iHoursVarchar				varchar(2),
	iMinutesVarchar				varchar(2),
	iSecondsVarchar				varchar(2),
	
	iTotalTimeReport			varchar(10),

)

-- physical stats table
if object_id('tempdb..#IndexPhysicalStats') is not null begin drop table #IndexPhysicalStats end

create table #IndexPhysicalStats (
	ipsDB_ID							int,
	ipsObject_ID						bigint,
	ipsIndex_ID							int,
	ipsFragment_count					bigint,
	ipsAvg_fragmentation_in_percent		decimal(5,2),
	ipsPage_Count						bigint)




---------------------------------------- DB Cursor Logic --------------------------------------------

declare @counter int = 1


declare DB_List cursor local fast_forward for
select dbName, dDB_ID
from @databases
order by dbName

open DB_List
fetch next from DB_List into @DBname, @DB_ID


while @@FETCH_STATUS = 0 begin

	-- progress messages
	set @Start = getdate()
	set @ProgressText = 'Getting tables / index list - ' + @DBname + '...'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT


	-- get table lists of the current database
	delete from #tables
	delete from #TableSizesMB

	set @GetTables = 'select case s.[name] when ''dbo'' then t.[name] else s.[name] + ''.'' + t.[name] end, [object_id] from ' + @DBName + '.sys.tables t join ' + @DBName + '.sys.schemas s on t.schema_id = s.schema_id'

	insert into #Tables (tTableName, tObject_ID)
	exec (@GetTables)

	-- get space used information for each individual table
	
	while @counter <= (select max(ID) from #tables) begin
	
		select @TableName = tTableName 
		from #Tables 
		where ID = @counter

		--print @TableName

		set @GetSpaceUsed = 'exec ' + @DBName + '.dbo.sp_spaceused ' + quotename(@TableName)

		--print @GetSpaceUsed

		insert into #TableSizesMB (tsTableName, tsRows, tsReserved, tsData, tsIndex_Size, tsUnused)
		exec (@GetSpaceUsed)

		set @counter += 1
	end


	update #TableSizesMB
		set tsObject_ID = tObject_ID,
			tsDBName = @DBname
	from #TableSizesMB
		join #Tables on
			tsTableName = tTableName
	where	tsDBName is NULL


	-- get integer size values in KB
	Update #TableSizesMB
		set tsData_Size_KB = cast(substring(tsData,1,charindex(' KB',tsData)) as bigint),
			tsIndex_Size_KB = cast(substring(tsIndex_Size,1,charindex(' KB',tsIndex_Size)) as bigint),
			tsUnused_Size_KB = cast(substring(tsUnused,1,charindex(' KB',tsUnused)) as bigint)

	update #TableSizesMB
		set tsTotal_Size_KB = tsData_Size_KB + tsIndex_Size_KB + tsUnused_Size_KB

	-- calculate size in MB
	Update #TableSizesMB
		set tsData_Size_MB = cast(tsData_Size_KB as decimal(16,2)) / 1024,
			tsIndex_Size_MB = cast(tsIndex_Size_KB as decimal(16,2)) / 1024,
			tsUnused_Size_MB = cast(tsUnused_Size_KB as decimal(16,2)) / 1024,
			tsTotal_Size_MB = cast(tsTotal_Size_KB as decimal(16,2)) / 1024


	-- calculate database total size
	update @databases
		set DBSizeMB_Before = (select sum(tsTotal_Size_MB) from #TableSizesMB)
	where	DBName = @DBname


	-- work with tables bigger than specified value (Megabytes)
	delete from #TableSizesMB
	where tsTotal_Size_MB < @TableSizeOver or tsTotal_Size_MB > @TableSizeUnder


	-- get index list
	set @GetIndexes = 'select tsDBName, s.[name], tsTableName, tsObject_ID, tsIndex_Size_MB, tsTotal_Size_MB, isnull(i.[name],''''), i.[index_id], i.[type_desc] from ' + @DBname + '.sys.indexes i join #TableSizesMB on tsObject_ID = i.[object_id] join ' + @DBName + '.sys.tables t on tsObject_ID = t.[object_id] join ' +  @DBName + '.sys.schemas s on t.schema_id = s.schema_id'

	insert into #Indexes (iDBName, iTableSchemaName, iTableName, iObject_ID, iTableIndexSizeBefore, iTableTotalSizeBefore, iIndexName, iIndex_ID, iType)
	exec (@GetIndexes)


	-- get schema name
	set @GetIndexes = 'update #Indexes set iTableSchemaName = s.[name] from #Indexes join ' + @DBname + '.sys.schemas s on '
	
	-- get database ids
	update #Indexes
		set iDB_ID = database_id
	from #Indexes
		join sys.databases on
			iDBName = [name]
	where	iDB_ID is NULL

	
	-- progress messages
	set @ProgressText = 'Gathering fragmentation levels - ' + @DBName + '...'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT


	-- get fragmentation level info
	insert into #IndexPhysicalStats (ipsDB_ID, ipsObject_ID, ipsIndex_ID, ipsFragment_count, ipsAvg_fragmentation_in_percent, ipsPage_Count)
	select 
		@DB_ID,
		[object_id],
		[index_id],
		fragment_count,
		avg_fragmentation_in_percent,
		page_count
	from sys.dm_db_index_physical_stats (@DB_ID,NULL,NULL,NULL,NULL)

	update #Indexes
		set iFragmentCountBefore = ipsFragment_count,
			iFragmentationPctBefore = ipsAvg_fragmentation_in_percent,
			iPageCountBefore = ipsPage_Count,
			iIndexSizeMBBefore = ipsPage_Count / 128
	from #Indexes i
		join #IndexPhysicalStats ips on
			iDB_ID = ipsDB_ID
			and iObject_ID = ipsObject_ID
			and iIndex_ID = ipsIndex_ID
	where	iDB_ID = @DB_ID

	-- progress messages
	set @End = getdate()
	set @Diff = datediff(second,@Start,@End)
	set @ProgressText = '-- ' + @DBname + ' -- Done in ' + cast(@Diff as varchar) + ' seconds
	'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT

	/*

	-- progress messages
	set @End = getdate()
	set @Diff = datediff(second,@Start,@End)
	set @ProgressText = @DBname + ' - Done in ' + cast(@Diff as varchar) + ' seconds'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT
	*/	

	-- next database
	fetch next from DB_List into @DBname, @DB_ID

end


close DB_List
deallocate DB_List


/*
-- get database ids
update #Indexes
	set iDB_ID = database_id
from #Indexes
	join sys.databases on
		iDBName = [name]



-- progress messages
set @Start = getdate()
set @ProgressText = 'Gathering fragmentation levels info' 
RAISERROR (@ProgressText, 0, 1) with NOWAIT


-- get fragmentation level info
update #Indexes
	set iFragmentCountBefore = fragment_count,
		iFragmentationPctBefore = avg_fragmentation_in_percent,
		iPageCountBefore = page_count
from #Indexes i
	join sys.dm_db_index_physical_stats (NULL,NULL,NULL,NULL,NULL) physicalstats on
		physicalstats.database_id = iDB_ID
		and i.[iObject_id] = physicalstats.[object_id]
		and i.[iIndex_id] = physicalstats.[index_id]


-- progress messages
set @End = getdate()
set @Diff = datediff(second,@Start,@End)
set @ProgressText = 'Gathering fragmentation levels info - done in ' + cast(@Diff as varchar) + ' seconds'
RAISERROR (@ProgressText, 0, 1) with NOWAIT
*/




------------------------------------------ Define Statements ------------------------------------------------

-- reorganize statement
update #Indexes 
	set iStatement = 'alter index ' + quotename(iIndexName) + ' on ' + quotename(iDBName) + '.[' + iTableSchemaName + '].' + quotename(iTableName) + ' REORGANIZE',
		iAction = 'REORGANIZE'
where	iType in ('CLUSTERED','NONCLUSTERED')
		and iFragmentationPctBefore >= @ReorganizeThreshold 
		and iFragmentationPctBefore < @RebuildThreshold



update #Indexes 
	set iStatement = 'alter index ' + quotename(iIndexName) + ' on ' + quotename(iDBName) + '.[' + iTableSchemaName + '].' + quotename(iTableName) + ' REBUILD with ( ONLINE=ON, MAXDOP=' + cast(@MaxDOP as varchar) + ' )',
		iAction = 'REBUILD'
where	iType in ('CLUSTERED','NONCLUSTERED') 
		and iFragmentationPctBefore >= @RebuildThreshold


-- heaps
if @RebuildHeapTables = 0 begin
	delete from #Indexes
	where iType in ('HEAP')

	set @ProgressText = cast(@@RowCount as varchar) + ' heaps are excluded due to @RebuildHeapTables = 0'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT

end

if @RebuildHeapTables = 1 begin
	update #Indexes 
		set iStatement = 'alter table ' + quotename(iDBName) + '.[dbo].' + quotename(iTableName) + ' REBUILD with ( ONLINE=ON )',
			iAction = 'REBUILD'
	where	iType in ('HEAP')
			and iFragmentationPctBefore >= @RebuildThreshold
end


-- rebuild / reorganize only
if @ReorganizeOnly = 1 begin
	delete from #Indexes 
	where iAction = 'REBUILD'
end

if @RebuildOnly = 1 begin
	delete from #Indexes 
	where iAction like 'REORGANIZE'
end	


-- remove rows where no action is needed
delete from #Indexes
where	iStatement is NULL
		and iType in ('CLUSTERED','NONCLUSTERED') 

set @ProgressText = cast(@@RowCount as varchar) + ' indexes do not need any defragmentation'
RAISERROR (@ProgressText, 0, 1) with NOWAIT


if @RebuildHeapTables = 1 begin
	delete from #Indexes
	where	iStatement is NULL
			and iType in ('HEAP') 

	set @ProgressText = cast(@@RowCount as varchar) + ' heaps do not need any defragmentation
	'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT
end



-- remove rows where index size (megabytes) is over specified threshold, and command is REBUILD 
if @DoNotRebuildIndexOver_MB > 0 begin
	delete from #Indexes
	where	iAction = 'REBUILD'
			and  iIndexSizeMBBefore > @DoNotRebuildIndexOver_MB

	set @ProgressText = cast(@@RowCount as varchar) + ' indexes that require rebuild, were ignored due to their size (MB) exceeding @DoNotRebuildIndexOver_MB value
	'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT

end





------------------------------------------ Report Only Option ------------------------------------------------

-- generate report only
if @GenerateReportOnly = 1 begin

	select 
		iDBName						[DatabaseName],
		iDB_ID						[DatabaseID],
		iTableName					[TableName],
		iObject_ID					[TableObjectID],
		iTableTotalSizeBefore		[TableTotalSizeMB],
		iIndex_ID					[IndexID],
		iType						[IndexType],
		iFragmentCountBefore		[FragmentCount],
		iFragmentationPctBefore		[FragmentationPercent],
		iPageCountBefore			[PageCount],
		iIndexSizeMBBefore			[IndexSizeMB],
		iAction						[Action],
		iStatement					[Statement]
	from #Indexes
	order by iDBName, iTableTotalSizeBefore, iIndexSizeMBBefore

end		-- end of Generate Report Only logic



------------------------------------------ Execute Statements ------------------------------------------------


if @GenerateReportOnly = 0 begin


-- cursor for executing rebuild / reorganize statements
declare ExecuteStatement cursor local fast_forward for
select 
	iID,
	iDBName,
	iTableTotalSizeBefore,
	iFragmentationPctBefore,
	iStatement 
from #Indexes
order by iDBName, iTableTotalSizeBefore, iFragmentationPctBefore

open ExecuteStatement
fetch next from ExecuteStatement into @iID, @DBName, @TableTotalSize, @FragmentationPctBefore, @ActionStatement


-- display progress
set @ProgressText = '
----- Execute Statements ------- 
	'
RAISERROR (@ProgressText, 0, 1) with NOWAIT


-- cursor logic
while @@FETCH_STATUS = 0 begin
	
	begin try
		
		-- run rebuild / reorganize statement
		set @Start = getdate()
			
		-- disply progress
		set @ProgressText = 'Executing "' + @ActionStatement + '"...'
		RAISERROR (@ProgressText, 0, 1) with NOWAIT

		-- execute statement
		exec (@ActionStatement)

		set @End = getdate()
		set @Diff = datediff(second,@Start,@End)

		-- record success
		update #Indexes
			set iSuccess = 1,
				iStartTime = @Start,
				iEndTime = @End
		where	iID = @iID

		-- disply progress
		set @ProgressText = '-- done in ' + cast(@Diff as varchar) + ' seconds
	' 
		RAISERROR (@ProgressText, 0, 1) with NOWAIT

	end try

	begin catch
		
		set @End = getdate() 

		-- display progress
		set @ProgressText = '-- FAILED!'
		RAISERROR (@ProgressText, 0, 1) with NOWAIT
		
		set @ProgressText = '-- ' + ERROR_MESSAGE() + '
	'
		RAISERROR (@ProgressText, 0, 1) with NOWAIT

		-- log error
		update #Indexes
			set iError = 1,
				iErrorMessage = ERROR_MESSAGE(),
				iStartTime = @Start,
				iEndTime = @End
		where	iID = @iID

	end catch

	-- next row
	fetch next from ExecuteStatement into @iID, @DBName, @TableTotalSize, @FragmentationPctBefore, @ActionStatement

end		-- end of ExecuteStatement cursor logic

close ExecuteStatement
deallocate ExecuteStatement






------------------------------------------ Gather Fragmentation Info After ------------------------------------------------

-- progress message
set @ProgressText = '
------ Gather Fragmentation Info After -----------
	'
RAISERROR (@ProgressText, 0, 1) with NOWAIT


delete from #IndexPhysicalStats
--set @counter = @counter


declare DB_List2 cursor local fast_forward for
select dbName, dDB_ID
from @databases
order by dbName

open DB_List2
fetch next from DB_List2 into @DBname, @DB_ID

-- collect physical stats for each database / table / index AFTER the defrag
while @@FETCH_STATUS = 0 begin

	-- progress messages
	set @Start = getdate()
	set @ProgressText = 'Getting tables / index list - ' + @DBname + ' - AFTER the defrag...'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT


	-- get table lists of the current database
	delete from #tables
	delete from #TableSizesMB

	set @GetTables = 'select case s.[name] when ''dbo'' then t.[name] else s.[name] + ''.'' + t.[name] end, [object_id] from ' + @DBName + '.sys.tables t join ' + @DBName + '.sys.schemas s on t.schema_id = s.schema_id'

	insert into #Tables (tTableName, tObject_ID)
	exec (@GetTables)

	-- get space used information for each individual table
	
	while @counter <= (select max(ID) from #tables) begin
	
		select @TableName = tTableName 
		from #Tables 
		where ID = @counter

		--print @TableName

		set @GetSpaceUsed = 'exec ' + @DBName + '.dbo.sp_spaceused ' + quotename(@TableName)

		--print @GetSpaceUsed

		insert into #TableSizesMB (tsTableName, tsRows, tsReserved, tsData, tsIndex_Size, tsUnused)
		exec (@GetSpaceUsed)

		set @counter += 1
	end


	update #TableSizesMB
		set tsObject_ID = tObject_ID,
			tsDBName = @DBname
	from #TableSizesMB
		join #Tables on
			tsTableName = tTableName
	where	tsDBName is NULL


	-- get integer size values in KB
	Update #TableSizesMB
		set tsData_Size_KB = cast(substring(tsData,1,charindex(' KB',tsData)) as bigint),
			tsIndex_Size_KB = cast(substring(tsIndex_Size,1,charindex(' KB',tsIndex_Size)) as bigint),
			tsUnused_Size_KB = cast(substring(tsUnused,1,charindex(' KB',tsUnused)) as bigint)

	update #TableSizesMB
		set tsTotal_Size_KB = tsData_Size_KB + tsIndex_Size_KB + tsUnused_Size_KB

	-- calculate size in MB
	Update #TableSizesMB
		set tsData_Size_MB = cast(tsData_Size_KB as decimal(16,2)) / 1024,
			tsIndex_Size_MB = cast(tsIndex_Size_KB as decimal(16,2)) / 1024,
			tsUnused_Size_MB = cast(tsUnused_Size_KB as decimal(16,2)) / 1024,
			tsTotal_Size_MB = cast(tsTotal_Size_KB as decimal(16,2)) / 1024

	
	-- calculate database total size AFTER defrag
	update @databases
		set DBSizeMB_After = (select sum(tsTotal_Size_MB) from #TableSizesMB)
	where	DBName = @DBname


	-- progress messages
	set @ProgressText = 'Gathering table / index sizes - ' + @DBName + ' - AFTER the defrag...'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT

	-- table / index total size AFTER defrag
	update #Indexes 
		set iTableIndexSizeAfter = tsIndex_Size_MB, 
			iTableTotalSizeAfter = tsTotal_Size_MB
	from #Indexes
		join #TableSizesMB on
			iTableName = tsTableName
			and iObject_ID = tsObject_ID
	where	iDB_ID = @DB_ID


	-- progress messages
	set @ProgressText = 'Gathering fragmentation levels - ' + @DBName + ' - AFTER the defrag...'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT


	-- get fragmentation level info
	insert into #IndexPhysicalStats (ipsDB_ID, ipsObject_ID, ipsIndex_ID, ipsFragment_count, ipsAvg_fragmentation_in_percent, ipsPage_Count)
	select 
		@DB_ID,
		[object_id],
		[index_id],
		fragment_count,
		avg_fragmentation_in_percent,
		page_count
	from sys.dm_db_index_physical_stats (@DB_ID,NULL,NULL,NULL,NULL)

	update #Indexes
		set iFragmentCountAfter = ipsFragment_count,
			iFragmentationPctAfter = ipsAvg_fragmentation_in_percent,
			iPageCountAfter = ipsPage_Count
	from #Indexes i
		join #IndexPhysicalStats ips on
			iDB_ID = ipsDB_ID
			and iObject_ID = ipsObject_ID
			and iIndex_ID = ipsIndex_ID
	where	iDB_ID = @DB_ID

	-- progress messages
	set @End = getdate()
	set @Diff = datediff(second,@Start,@End)
	set @ProgressText = '-- ' + @DBname + ' -- Done in ' + cast(@Diff as varchar) + ' seconds
	'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT

	-- next database
	fetch next from DB_List2 into @DBname, @DB_ID


end		-- end of getting fragmentation stats after

close DB_List2
deallocate DB_List2





-- calculate database size reduction
update @databases
	set ReducedBy = DBSizeMB_Before - DBSizeMB_After,
		ReductionPct = ((DBSizeMB_Before - DBSizeMB_After) / DBSizeMB_Before) * 100

-- calculate table size reduction
update #Indexes
	set iTableSizeReducedBy = iTableTotalSizeBefore - iTableTotalSizeAfter,
		iTableSizeReductionPct = ((iTableTotalSizeBefore - iTableTotalSizeAfter) / iTableTotalSizeBefore) * 100





------------------------------------------ Calculate Time Spent ------------------------------------------------

set @GlobalEnd = getdate()

declare @TotalTimeSpent table (
	ttsGlobalStart			datetime,
	ttsGlobalEnd			datetime,

	ttsHours				int,
	ttsMinutes				int,
	ttsSeconds				int,

	ttsHoursVarchar			varchar(2),
	ttsMinutesVarchar		varchar(2),
	ttsSecondsVarchar		varchar(2),

	ttsTotalTimeReport		varchar(10))


-- calculate total time spent
insert into @TotalTimeSpent (ttsGlobalStart, ttsGlobalEnd)
select @GlobalStart, @GlobalEnd
		
update 	@TotalTimeSpent	
	set ttsHours = case 
						when datediff(minute,@GlobalStart,@GlobalEnd) < 60 and datediff(hour,@GlobalStart,@GlobalEnd) > 0 then 0
						else datediff(hour,@GlobalStart,@GlobalEnd)
					end,
		ttsMinutes = case 
						when datediff(second,@GlobalStart,@GlobalEnd) < 60 and (datediff(minute,@GlobalStart,@GlobalEnd) - ((datediff(minute,@GlobalStart,@GlobalEnd)) / 60) * 60) > 0 then 0
						else datediff(minute,@GlobalStart,@GlobalEnd) - ((datediff(minute,@GlobalStart,@GlobalEnd)) / 60) * 60
					end,
		ttsSeconds = datediff(second,@GlobalStart,@GlobalEnd) - ((datediff(second,@GlobalStart,@GlobalEnd)) / 60) * 60


-- calculate time spent on each index defrag operation
update #Indexes
	set iHours = case 
						when datediff(minute,iStartTime,iEndTime) < 60 and datediff(hour,iStartTime,iEndTime) > 0 then 0
						else datediff(hour,iStartTime,iEndTime)
					end,
		iMinutes = case 
						when datediff(second,iStartTime,iEndTime) < 60 and (datediff(minute,iStartTime,iEndTime) - ((datediff(minute,iStartTime,iEndTime)) / 60) * 60) > 0 then 0
						else datediff(minute,iStartTime,iEndTime) - ((datediff(minute,iStartTime,iEndTime)) / 60) * 60
					end,
		iSeconds = datediff(second,iStartTime,iEndTime) - ((datediff(second,iStartTime,iEndTime)) / 60) * 60

update #Indexes
	set iHoursVarchar = right('00' + cast(iHours as varchar),2),
		iMinutesVarchar = right('00' + cast(iMinutes as varchar),2),
		iSecondsVarchar = right('00' + cast(iSeconds as varchar),2)


update @TotalTimeSpent
	set ttsHoursVarchar = right('00' + cast(ttsHours as varchar),2),
		ttsMinutesVarchar = right('00' + cast(ttsMinutes as varchar),2),
		ttsSecondsVarchar = right('00' + cast(ttsSeconds as varchar),2)


update #Indexes
	set iTotalTimeReport = iHoursVarchar + ':' + iMinutesVarchar + ':' + iSecondsVarchar

update @TotalTimeSpent
	set ttsTotalTimeReport = ttsHoursVarchar + ':' + ttsMinutesVarchar + ':' + ttsSecondsVarchar

	



------------------------------------------ Report's Body Message ------------------------------------------------

-- progress message
set @ProgressText = '
-------- Building Email Report Body Message -----------
	'
RAISERROR (@ProgressText, 0, 1) with NOWAIT


-- time spent
declare @TotalTimeSpentReport varchar(10)
set @TotalTimeSpentReport = (select ttsTotalTimeReport from @TotalTimeSpent)


set @msg = @msg + '	Total Job Run Time: ' + @TotalTimeSpentReport + '

'


-- db size cursor
set @msg = @msg + '	Databases:
	
'

declare DBSize cursor local fast_forward for
select 
	[DBName],
	DBSizeMB_Before,
	DBSizeMB_After,
	ReducedBy,
	ReductionPct
from @databases
order by [DBNAME]


open DBSize
fetch next from DBSize into @DBName, @SizeBeforeMB, @SizeAfterMB, @ReducedBy, @ReductionPct

while @@Fetch_status = 0 begin

	set @msg = @msg + @DBName + ' -- BEFORE -- ' + cast(@SizeBeforeMB as varchar) + ' MB -- AFTER -- ' +  cast(@SizeAfterMB as varchar) + ' MB -- reduced by ' + cast(@ReducedBy as varchar) + 'MB ( ' + cast(@ReductionPct as varchar) + ' % )
'
	set @msg = @msg + '
'
	
	print 'Running DBSize cursor for ' + @DBName
	--print @msg

	-- next database size
	fetch next from DBSize into @DBName, @SizeBeforeMB, @SizeAfterMB, @ReducedBy, @ReductionPct	

end		-- end of db size cursor logic

close DBSize
deallocate DBSize


set @msg = @msg + '
	
'


-- table sizes
set @msg = @msg + '	Tables:
	
'

declare TableSize cursor local fast_forward for
select distinct 
	iDBName, 
	iTableName, 
	iTableTotalSizeBefore, 
	iTableTotalSizeAfter, 
	iTableSizeReducedBy,
	iTableSizeReductionPct
from #Indexes
order by iDBName, iTableName, iTableTotalSizeBefore, iTableTotalSizeAfter

open TableSize
fetch next from TableSize into @DBName, @TableName, @SizeBeforeMB, @SizeAfterMB, @ReducedBy, @ReductionPct


while @@Fetch_status = 0 begin

	set @msg = @msg + @DBname + '..' + @TableName + ' -- BEFORE -- ' + cast(@SizeBeforeMB as varchar) + ' MB -- AFTER -- ' +  cast(@SizeAfterMB as varchar) + ' MB -- reduced by ' + cast(@ReducedBy as varchar) + ' MB ( ' + cast(@ReductionPct as varchar) + ' % )
'	
	
	set @msg = @msg + '
'

	print 'Running TableSize cursor for ' + @DBname + '..' + @TableName
	--print @msg

	-- next table
	fetch next from TableSize into @DBName, @TableName, @SizeBeforeMB, @SizeAfterMB, @ReducedBy, @ReductionPct

end			-- end of table size cursor logic

close TableSize
deallocate TableSize

	
set @msg = @msg + '

	Details:

'

--print @msg

-- cursor for building report's body message
declare IndexDefragDetails cursor local fast_forward for
select 
	iDBName, 
	iTableName,
	iIndexName,
	iType,
	iStatement,
	iAction,
	iFragmentCountBefore,
	iFragmentCountAfter,
	iFragmentationPctBefore,
	iFragmentationPctAfter,
	iPageCountBefore,
	iPageCountAfter,
	iSuccess,
	iStartTime,
	iEndTime,
	iError,
	iErrorMessage,
	iTotalTimeReport
from #Indexes
order by iDBName, iTableTotalSizeBefore, iFragmentationPctBefore


open IndexDefragDetails
fetch next from IndexDefragDetails into @DBName, @TableName, @IndexName, @Type, @ActionStatement, @Action, @FragmentCountBefore,
	@FragmentCountAfter, @FragmentationPctBefore, @FragmentationPctAfter, @PageCountBefore, @PageCountAfter, 
	@Success, @Start, @End, @Error, @ErrorMessage, @TimeSpentOnOperation

while @@Fetch_status = 0 begin
	
	if @Success = 1 begin
		
		print 'Running IndexDefragDetails cursor for ' + @DBName + '..' + @TableName + '..' + @IndexName

		set @msg = @msg + @DBName + '..' + @TableName + ' (' + @IndexName + ') -- ' + @Type + ' -- ' + @Action + '
		Page Count -- Before -- ' + cast(@PageCountBefore as varchar) + ' -- After -- ' + cast(@PageCountAfter as varchar) + '
		Fragment Count -- Before -- ' + cast(@FragmentCountBefore as varchar) + ' -- After -- ' + cast(@FragmentCountAfter as varchar) + '
		Fragmentation Percent -- Before -- ' + cast(@FragmentationPctBefore as varchar) + ' -- After -- ' + cast(@FragmentationPctAfter as varchar) + '
		Time Spent -- ' + @TimeSpentOnOperation + '

'	--print @msg
	end		-- success logic end

	--print left(@msg,100)

	if @Error = 1 begin
	
		set @msg = @msg + @DBName + '..' + @TableName + ' (' + @IndexName + ') -- ' + @Type + ' -- ' + @Action + '
		FAILED -- ' + @ErrorMessage + '

'
	end		-- failed operation logic end
		

	-- next operation info
	fetch next from IndexDefragDetails into @DBName, @TableName, @IndexName, @Type, @ActionStatement, @Action, @FragmentCountBefore,
		@FragmentCountAfter, @FragmentationPctBefore, @FragmentationPctAfter, @PageCountBefore, @PageCountAfter, 
		@Success, @Start, @End, @Error, @ErrorMessage, @TimeSpentOnOperation

end			-- end of building report's body message cursor logic


close IndexDefragDetails
deallocate IndexDefragDetails




-- email
if @SendReportEmail = 1 begin

set @SubjectText = 'Index Defrag Report'

EXEC msdb.dbo.sp_send_dbmail 
	@profile_name = @EmailProfileName, 
	@recipients = @toList, 
	@subject = @SubjectText, 
	@body = @msg

end			-- end of email send procedure




-- progress message
set @ProgressText = '
---------- Email Report -----------
	'
RAISERROR (@ProgressText, 0, 1) with NOWAIT

print @msg




end		-- end of Execute Statements / report results logic

end		-- end of procedure logic


