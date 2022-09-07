


create or alter procedure ServerSpaceUsage as begin

/****************************************************** SERVER SPACE USAGE PROCEDURE **************************************************

Author: Aleksey Vitsko

Version: 1.03

Description: this procedure shows size information for each database on the instance
Shows total size and total space used for each data file / log file for each database

History

2022-09-07 --> Aleksey Vitsko - use sys.master_files instead of cycling through each database's sys.database_files
2020-07-20 --> Aleksey Vitsko - ONLINE state databases only
2019-02-07 --> Aleksey Vitsko - added drive / volume space usage info in the output
2018-01-15 --> Aleksey Vitsko - created procedure


****************************************************************************************************************************************/



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




-- get details for database data/log files
insert into #DatabasesAndFiles (dDB_ID, dType_Desc, dPhysical_Path, dLogical_FileName, dSizeMB, dMax_SizeMB, dGrowth_MB_or_Pct, dGrowthOption)
select 
	database_id,
	[type_desc], 
	physical_name, 
	[name], size / 128, 
	case max_size 
		when -1 then -1 
		else cast(max_size as bigint) / 128 
	end, 
	growth, 
	case is_percent_growth 
		when 0 then 'Fixed Space' 
		else 'Percent' 
	end 
from sys.master_files


-- get database name
update #DatabasesAndFiles
	set dDB_Name = [name]
from #DatabasesAndFiles
	join sys.databases on
		dDB_ID = database_id



-- get space used for each data file
declare @ExecStatement varchar(500)

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



end

