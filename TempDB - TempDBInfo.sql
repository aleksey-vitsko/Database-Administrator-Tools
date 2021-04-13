

create or alter procedure TempDBInfo (@command varchar(20) = 'all')  
as begin 

/****************************************** TempDBInfo procedure ***********************************************

Author: Aleksey Vitsko
Created: August 2020

Description: shows TempDB information
Example: exec TempDBInfo

Can be deployed to any database (system or user)


--------------------------------------------------------------------------------------------------------------------------

Accepts arguments (@command):



--------------------------------------------------------------------------------------------------------------------------

Version: 1.00

Change history:

2020-08-04 - Aleksey Vitsko - Created procedure

*************************************************************************************************************************/

set nocount on

---------------------------------------------------- Variables -------------------------------------------------------


declare 
	@TempDB_Total_MB					int,
	
	@DataFile_Total_MB					int,
	@DataFile_NumberOfFiles				int,
	@DataFile_SpaceUsed_Percent			decimal(5,2), 

	@LogFile_Total_MB					int,
	@LogFile_NumberOfFiles				int,
	@Log_SpaceUsed_Percent				decimal(5,2), 
	@Log_SpaceUsed_MB					int






drop table if exists #TempDB_Files_SpaceUsage

create table #TempDB_Files_SpaceUsage (
	tFileID						int primary key,
	tType_Desc					nvarchar(60),
	tName						sysname NULL,
	tPhysical_Name				nvarchar(260),
	tState_Desc					nvarchar(60),

	tTotal_MB					decimal(16,2),
	tAllocated_MB				decimal(16,2),
	tUnallocated_MB				decimal(16,2),
	
	tVersionStore_MB			decimal(16,2),
	tUserObject_MB				decimal(16,2),
	tInternalObject_MB			decimal(16,2),
	tMixedExtent_MB				decimal(16,2),
	tModifiedExtent_MB			decimal(16,2),
	
	tPercentage_Full			decimal(5,2))


-- data files
insert into #TempDB_Files_SpaceUsage (tFileID, tTotal_MB, tAllocated_MB, tUnallocated_MB, tVersionStore_MB, tUserObject_MB, tInternalObject_MB, tMixedExtent_MB, tModifiedExtent_MB)
select 
	[file_id],
	cast(total_page_count as decimal(16,2)) / 128,
	cast(allocated_extent_page_count as decimal(16,2)) / 128,
	cast(unallocated_extent_page_count as decimal(16,2)) / 128,
	cast(version_store_reserved_page_count as decimal(16,2)) / 128,
	cast(user_object_reserved_page_count as decimal(16,2)) / 128,
	cast(internal_object_reserved_page_count as decimal(16,2)) / 128,
	cast(mixed_extent_page_count as decimal(16,2)) / 128,
	cast(modified_extent_page_count as decimal(16,2)) / 128
from tempdb.sys.dm_db_file_space_usage


-- log file
insert into #TempDB_Files_SpaceUsage (tFileID, tName, tPhysical_Name, tState_Desc, tTotal_MB)
select 
	[file_id],
	[name],
	physical_name,
	state_desc,
	cast(size as decimal(16,2)) / 128
from sys.master_files
where	[database_id] = 2
		and [type] = 1


	

-- file names
update #TempDB_Files_SpaceUsage
	set tName = [name],
		tPhysical_Name = physical_name,
		tState_Desc = state_desc,
		tType_Desc = [type_desc]
from #TempDB_Files_SpaceUsage
	join sys.master_files on
		tFileID = [file_id]
		and [database_id] = 2


-- data and log file total size
select 
	@DataFile_Total_MB = sum(tTotal_MB),
	@DataFile_NumberOfFiles = count(*)
from #TempDB_Files_SpaceUsage where tType_Desc = 'ROWS'

select 
	@LogFile_Total_MB = sum(tTotal_MB),
	@LogFile_NumberOfFiles = count(*)
from #TempDB_Files_SpaceUsage where tType_Desc = 'LOG'


set @TempDB_Total_MB = @DataFile_Total_MB + @LogFile_Total_MB



-- calculate percentage full
update #TempDB_Files_SpaceUsage
	set tPercentage_Full = (tAllocated_MB / tTotal_MB) * 100

set @DataFile_SpaceUsed_Percent = (select (sum(tAllocated_MB) / sum(tTotal_MB)) * 100 from #TempDB_Files_SpaceUsage where tType_Desc = 'ROWS')





-- log space
drop table if exists #DBCCSQLPerfLogSpace

create table #DBCCSQLPerfLogSpace (
	[DB_Name]				varchar(100) primary key,
	LogSize					decimal(16,2),
	LogSpaceUsedPct			decimal(5,2),
	[Status]				int)

insert into #DBCCSQLPerfLogSpace ([DB_Name], LogSize, LogSpaceUsedPct, [Status])
exec ('dbcc sqlperf (logspace)')



set @Log_SpaceUsed_Percent = (select LogSpaceUsedPct from #DBCCSQLPerfLogSpace where [DB_Name] = 'tempDB')
set @Log_SpaceUsed_MB = (select (LogSize * LogSpaceUsedPct) / 100 from #DBCCSQLPerfLogSpace where [DB_Name] = 'tempDB')





-- TempDB summary
drop table if exists #TempDB_Info 

create table #TempDB_Info (
	Property			varchar(50),
	[Value]				varchar(500))

insert into #TempDB_Info (Property, [Value])
values	('Total TempDB size ',cast(@TempDB_Total_MB as varchar) + ' Megabytes ( ' + cast(@TempDB_Total_MB / 1024 as varchar) + ' GB )'),
		('Number of data files',cast(@DataFile_NumberOfFiles as varchar) + ' data file(s)'),
		('Data file total size',cast(@DataFile_Total_MB as varchar) + ' Megabytes (' + cast(@DataFile_Total_MB / 1024 as varchar) + ' GB )'),
		('Current data file fullness (percent)',cast(@DataFile_SpaceUsed_Percent as varchar) + ' %')
		


select * from #TempDB_Info







select
	@TempDB_Total_MB					[TempDB_Total_MB],
	
	@DataFile_NumberOfFiles				[Number_Of_Data_Files],
	@DataFile_Total_MB					[Data_File_Total_MB],
	@DataFile_SpaceUsed_Percent			[Data_Percentage_Full],

	@LogFile_Total_MB					[Log_File_Total_MB],
	@LogFile_NumberOfFiles				[Number_Of_Log_Files],
	@Log_SpaceUsed_Percent				[Log_Full_Pct],

	sum(tAllocated_MB)					[Allocated_MB],
	sum(tUnallocated_MB)				[Unallocated_MB],
	sum(tVersionStore_MB)				[VersionStore_MB],
	sum(tUserObject_MB)					[UserObject_MB], 
	sum(tInternalObject_MB)				[InternalObject_MB],
	sum(tMixedExtent_MB)				[MixedExtent_MB],
	sum(tModifiedExtent_MB)				[ModifiedExtent_MB]	

from #TempDB_Files_SpaceUsage


-- TempDB data file details
select
	tFileID					[File_ID],
	tType_Desc				[Type_Desc],
	tName					[Name],
	tPhysical_Name			[Physical_Name],
	tState_Desc				[State_Desc],
	tTotal_MB				[Total_MB],
	tAllocated_MB			[Allocated_MB],
	tUnallocated_MB			[Unallocated_MB],
	tVersionStore_MB		[VersionStore_MB],
	tUserObject_MB			[UserObject_MB],
	tInternalObject_MB		[InternalObject_MB],
	tMixedExtent_MB			[MixedExtent_MB],
	tModifiedExtent_MB		[ModifiedExtent_MB],
	tPercentage_Full		[Percentage_Full]
from #TempDB_Files_SpaceUsage




-- sessions that use TempDB
drop table if exists #TempDB_Sessions

create table #TempDB_Sessions (
	Session_ID				int,
	Login_Name				sysname,

	User_Alloc_MB			decimal(16,2),
	User_Dealloc_MB			decimal(16,2),

	Internal_Alloc_MB		decimal(16,2),
	Internal_Dealloc_MB		decimal(16,2),

	Current_MB				decimal(16,2))



insert into #TempDB_Sessions (Session_ID, Login_Name, User_Alloc_MB, User_Dealloc_MB, Internal_Alloc_MB, Internal_Dealloc_MB, Current_MB)
select 
	ssu.session_id,
	s.login_name, 
	
	cast(user_objects_alloc_page_count as decimal(20,2)) / 128,
	cast(user_objects_dealloc_page_count as decimal(20,2)) / 128,
	cast(internal_objects_alloc_page_count as decimal(20,2)) / 128,
	cast(internal_objects_dealloc_page_count as decimal(20,2)) / 128,
	
	((cast(user_objects_alloc_page_count as decimal(20,2)) + cast(internal_objects_alloc_page_count as decimal(20,2))) - (cast(user_objects_dealloc_page_count as decimal(20,2)) + cast(internal_objects_dealloc_page_count as decimal(20,2)))) / 128

from sys.dm_db_session_space_usage ssu
	join sys.dm_exec_sessions s on
		ssu.session_id = s.session_id


select * 
from #TempDB_Sessions
where Current_MB > 0
order by Current_MB




-- tasks that use TempDB
drop table if exists #TempDB_Tasks

create table #TempDB_Tasks (
	Session_ID				int,
	Login_Name				sysname,
	Task_Address			varbinary(100),

	User_Alloc_MB			decimal(16,2),
	User_Dealloc_MB			decimal(16,2),

	Internal_Alloc_MB		decimal(16,2),
	Internal_Dealloc_MB		decimal(16,2),

	Current_MB				decimal(16,2))


insert into #TempDB_Tasks (Session_ID, Login_Name, Task_Address, User_Alloc_MB, User_Dealloc_MB, Internal_Alloc_MB, Internal_Dealloc_MB, Current_MB)
select 
	tsu.session_id,
	s.login_name, 
	task_address,

	cast(user_objects_alloc_page_count as decimal(20,2)) / 128,
	cast(user_objects_dealloc_page_count as decimal(20,2)) / 128,
	cast(internal_objects_alloc_page_count as decimal(20,2)) / 128,
	cast(internal_objects_dealloc_page_count as decimal(20,2)) / 128,
	
	((cast(user_objects_alloc_page_count as decimal(20,2)) + cast(internal_objects_alloc_page_count as decimal(20,2))) - (cast(user_objects_dealloc_page_count as decimal(20,2)) + cast(internal_objects_dealloc_page_count as decimal(20,2)))) / 128

from sys.dm_db_task_space_usage tsu
	join sys.dm_exec_sessions s on
		tsu.session_id = s.session_id


select * 
from #TempDB_Tasks
where Current_MB > 0
order by Current_MB





/*


exec DatabaseSizeSP

select * from sys.databases

select * from sys.dm_exec_sessions



select * from sys.dm_db_file_space_usage

select * from sys.database_files

select * from sys.master_files





select * from tempdb.sys.dm_db_file_space_usage

select * from tempdb.sys.database_files




select s.login_name, ssu.* 
from sys.dm_db_session_space_usage ssu
	join sys.dm_exec_sessions s on
		ssu.session_id = s.session_id





select s.login_name, tsu.* 
from sys.dm_db_task_space_usage tsu
	join sys.dm_exec_sessions s on
		tsu.session_id = s.session_id



*/



end
