
-- use [master]
-- use [IntlBridgeDB]

create or alter procedure DatabaseSizeSP as begin

/*************************************** Database Size SP ********************************************

Author: Aleksey Vitsko
Created: Jan 2018

Remarks:

This procedure shows size information for each database on the instance
Shows total size and total space used for each data file / log file for each database

Version: 1.02

---------------------------------------

History

2020-07-20 - Aleksey Vitsko - ONLINE state databases only
2019-02-07 - Aleksey Vitsko - added drive / volume space usage info in the output
2018-01-15 - Aleksey Vitsko - created procedure


***************************************************************************************************/



if object_ID('TempDB..#DatabasesAndFiles') is not NULL begin drop table #DatabasesAndFiles end
if object_ID('TempDB..#DBCCSQLPerfLogSpace') is not NULL begin drop table #DBCCSQLPerfLogSpace end
if object_ID('TempDB..#Results') is not NULL begin drop table #Results end


create table #DatabasesAndFiles (
	dDB_ID						int,
	dDB_Name					varchar(100),
	dType_Desc					varchar(5),
	dPhysical_Path				varchar(200),
	dLogical_FileName			varchar(100),

	dSizeMB						decimal(16,2),
	dSpaceUsedMB				decimal(16,2) default 0,
	dSpaceUsedPct				decimal(5,2),

	dMax_SizeMB					bigint,
	dGrowth_MB_or_Pct			int,
	dGrowthOption				varchar(15))

create clustered index CIX_DB_Name_Type on #DatabasesAndFiles (dType_Desc desc, dDB_Name, dLogical_FileName )


create table #DBCCSQLPerfLogSpace (
	lDB_Name				varchar(100) primary key,
	lLogSize				decimal(16,2),
	lLogSpaceUsedPct		decimal(5,2),
	lStatus					int)


create table #Results (
	rDB_ID						int primary key,
	rDB_Name					varchar(100),

	rDataFilesSizeMB			decimal(16,2),
	rDataFilesUsedMB			decimal(16,2),
	rDataFileUsedPct			decimal(5,2),

	rLogFilesSizeMB				decimal(16,2),
	rLogFilesUsedMB				decimal(16,2),
	rLogFilesUsedPct			decimal(5,2),

	rTotalDBSizeMB				int)


declare 
	@DB_ID int, 
	@DB_Name varchar(100),
	@ExecStatement varchar(500)

declare DatabaseCursor cursor local fast_forward for
select database_id, [name] 
from sys.databases
where state_desc in ('ONLINE')
order by [name]

open DatabaseCursor
fetch next from DatabaseCursor into @DB_ID, @DB_Name

while @@fetch_status = 0 begin
	
	set @ExecStatement = 'select [type_desc], physical_name, [name], size / 128, case max_size when -1 then -1 else cast(max_size as bigint) / 128 end, growth, case is_percent_growth when 0 then ''Fixed Space'' else ''Percent'' end from ' + @DB_Name + '.sys.database_files'

	print @ExecStatement

	-- insert database files info
	insert into #DatabasesAndFiles (dType_Desc, dPhysical_Path, dLogical_FileName, dSizeMB, dMax_SizeMB, dGrowth_MB_or_Pct, dGrowthOption)
	exec (@ExecStatement)

	-- database ID and name
	update #DatabasesAndFiles
		set dDB_ID = @DB_ID,
			dDB_Name = @DB_Name
	where	dDB_ID is NULL
			and dDB_Name is NULL

	fetch next from DatabaseCursor into @DB_ID, @DB_Name

end		-- end of cursor logic


-- get space used for each data file
set @ExecStatement = 'use [?]; update #DatabasesAndFiles set dSpaceUsedMB = fileproperty(dLogical_FileName,''spaceused'') / 128 where dDB_Name = db_name()'		-- and dType_Desc = ''ROWS''
exec sp_msforeachdb @ExecStatement


/*
update #DatabasesAndFiles
	set dSpaceUsedMB = dSpaceUsedMB / t.[cnt]
from #DatabasesAndFiles
	join (select dDB_Name [tDB_Name], count(*) [cnt]
			from #DatabasesAndFiles
			where dType_Desc = 'ROWS'
			group by dDB_Name
			having count(*) > 1) t on
		dDB_Name = [tDB_Name]
where	dType_Desc = 'ROWS'
*/

update #DatabasesAndFiles
	set dSpaceUsedPct = cast(dSpaceUsedMB as decimal(8,2)) / cast(dSizeMB as decimal(8,2)) * 100
where dSizeMB <> 0

update #DatabasesAndFiles
	set dSpaceUsedPct = 0
where dSizeMB = 0

update #DatabasesAndFiles
	set dGrowth_MB_or_Pct = dGrowth_MB_or_Pct / 128
where dGrowthOption = 'Fixed Space'





------------------------------------------------ Results Table ------------------------------------------------

-- populate results table with distinct database list
insert into #Results (rDB_ID, rDB_Name)
select distinct dDB_ID, dDB_Name
from #DatabasesAndFiles

-- data files total size and usage
update #Results
	set rDataFilesSizeMB = t.DataFilesSizeMB,
		rDataFilesUsedMB = t.DataFilesUsedMB
from #Results
	join (select 
			dDB_Name				[dDB_Name],
			sum(dSizeMB)			[DataFilesSizeMB],
			sum(dSpaceUsedMB)		[DataFilesUsedMB]
			from #DatabasesAndFiles
			where dType_Desc = 'ROWS'
		group by dDB_Name) t on

		rDB_Name = t.dDB_Name


update #Results
	set rDataFileUsedPct = (rDataFilesUsedMB / rDataFilesSizeMB) * 100


-- log space
insert into #DBCCSQLPerfLogSpace (lDB_Name, lLogSize, lLogSpaceUsedPct, lStatus)
exec ('dbcc sqlperf (logspace)')

update #Results
	set rLogFilesSizeMb = lLogSize,
		rLogFilesUsedPct = lLogSpaceUsedPct
from #Results
	join #DBCCSQLPerfLogSpace on
		rDB_Name = lDB_Name


update #Results
	set rLogFilesUsedMB = rLogFilesSizeMB * rLogFilesUsedPct / 100

-- total database size
update #Results
	set rTotalDBSizeMB = rDataFilesSizeMB + rLogFilesSizeMB



--------------------------------------------- Results ------------------------------------------------

-- show drive / volume space usage
select 
	volume_mount_point, 
	count(*)								[Total_Database_Files], 
	total_bytes / 1024 / 1024 / 1024		[Volume_Size_GB], 
	sum(size / 128 / 1024)					[Total_Database_Size_GB],
	available_bytes / 1024 / 1024 / 1024	[Free_Space_GB]
from sys.master_files AS f  
CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id) 
group by volume_mount_point, total_bytes / 1024 / 1024 / 1024, available_bytes / 1024 / 1024 / 1024
order by volume_mount_point




-- show results
select 
	rDB_Name				[Database Name], 
	
	rDataFilesSizeMB		[Data File Size],
	--rDataFilesUsedMB,
	rDataFileUsedPct		[Data File Usage Pct],
	
	rLogFilesSizeMB			[Log File Size],
	--rLogFilesUsedMB,
	rLogFilesUsedPct		[Log File Usage Pct],

	rTotalDBSizeMB			[Total DB Size]
from #Results
order by rTotalDBSizeMB desc


-- show details
select * from #DatabasesAndFiles





-- select fileproperty('TestDB','spaceused') / 128

/*

exec #DBCC_SQLPERF_LOGSPACE

*/


/*

dbcc sqlperf (logspace)


use IntlBridgeDB

select * from TestDB.sys.database_files

exec sp_helpdb

exec sp_spaceused

select (sum (size)) * 8 / 1024 
from IntlBridgeDB.sys.database_files
where type_desc = 'ROWS'


select [type_desc], physical_name, (size * 8) / 1024, 
case max_size when -1 then -1 else (cast(max_size as bigint) * 8) / 1024 end, growth, is_percent_growth from ASPState.sys.database_files



SELECT DB_NAME() AS DbName, 
[name] AS FileName, 
size/128.0 AS CurrentSizeMB, 
size/128.0 - CAST(FILEPROPERTY(name, 'SpaceUsed') AS INT)/128.0 AS FreeSpaceMB 
FROM sys.database_files; 


select fileproperty('IntlBridgeDB','spaceused') / 128

*/

end

