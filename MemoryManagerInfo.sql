

create or alter procedure MemoryManagerInfo (
	@ExpertMode			tinyint = 0)

as begin	

set nocount on

/***************************************************MEMORY MANAGER INFO PROCEDURE ********************************************************

Author: Aleksey Vitsko

Version: 1.11

Purpose: shows current memory usage 
(how much RAM memory is being used by the Database Engine, and what for: database cache, plan cache, memory grants, connections, locks, etc.)

History:

2025-03-27 --> Aleksey Vitsko - show all memory clerks in Expert mode (to include SQLBUFFERPOOL)
2024-03-15 --> Aleksey Vitsko - percentage for "Maximum Workspace Memory" should be calculated in relation to "Target Server Memory", not "Total Server Memory" (issue https://github.com/aleksey-vitsko/Database-Administrator-Tools/issues/3)
2024-02-16 --> Aleksey Vitsko - make SP show memory counters information on Azure SQL Managed Instance and Azure SQL DB
2022-09-06 --> Aleksey Vitsko - slight updates to perf.counter description texts
2022-09-06 --> Aleksey Vitsko - added information from "sys.dm_os_memory_clerks" to output in the Expert Mode = 1
2022-08-27 --> Aleksey Vitsko - added @ExpertMode parameter - 0 is default and is simpler output, 1 will show all columns and details
2022-08-26 --> Aleksey Vitsko - added "counter_location" column to the output
2022-08-26 --> Aleksey Vitsko - added "percentage_info" column to the output
2022-08-26 --> Aleksey Vitsko - corrections to perf.counter descriptions to make them more understandable
2022-08-26 --> Aleksey Vitsko - added "Server Total RAM" to the output
2022-06-10 --> Aleksey Vitsko - lets have "cntr_value_GB" show decimal values, too
2019-11-05 --> Aleksey Vitsko - added "Plan Cache" memory info
2019-11-01 --> Aleksey Vitsko - created procedure

***************************************************************************************************************************************/



-- @ExpertMode validation
if @ExpertMode not in (0,1) begin
	print '@ExpertMode can only be 0 or 1'
	return
end


-- use temp table
if object_id('TempDB..#MemoryManager') is not NULL begin drop table #MemoryManager end

create table #MemoryManager (
	ID					int identity primary key,
	
	counter_name		varchar(100),			-- PerfMon counter name
	counter_location	varchar(100),
	counter_desc		varchar(500),			-- counter description
	
	cntr_value			bigint,					-- value in kilobytes
	cntr_value_MB		bigint,					-- value in megabytes
	cntr_value_GB		decimal(8,2),			-- value in gigabytes

	pct					decimal(5,2),
	percentage_info		varchar(100)

	)


-- insert memory manager performance counter names with descriptions
insert into #MemoryManager (counter_name, counter_location, counter_desc)
values	('Total Server Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Total amount of memory SQL Server is currently consuming ("Database Cache Memory" + "Stolen Server Memory" + "Free Memory")'),
		('Target Server Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Total amount of memory SQL Server is allowed to consume (can be limited by "max server memory" setting)'),
		('Database Cache Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server is currently using for cached 8-kb database pages'),
		('Maximum Workspace Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Maximum amount of memory available for grants to executing processes. This memory is used primarily for hash, sort and create index operations'),
		('Stolen Server Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server is using not for cached database pages (Plan Cache + Memory Grants + Locks + Connections + other)'),
		('Lock Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server is using for locks (lock manager)'),
		('Free Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server is currently not using.'),
		('Log Pool Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server is using for Log Pool'),
		('SQL Cache Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server is using for the dynamic SQL cache'),
		('Connection Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL server is using for maintaining connections'),
		('Optimizer Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server is using for query optimizer'),
		('Reserved Server Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server has reserved for future usage. This counter shows current unused amount of the initial grant shown in Granted Workspace Memory'),
		('Granted Workspace Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory granted to executing processes. This memory is used for hash, sort and create index operations'),
		('Plan Cache','sys.dm_exec_cached_plans (size_in_bytes)','Amount of memory used for cached query execution plans')


-- get memory manager performance counters current values
update m
	set m.cntr_value = pc.cntr_value
from #MemoryManager m
	join sys.dm_os_performance_counters pc on
		left(m.counter_name,10) = left(pc.counter_name,10)
		and [object_name] like '%Memory Manager%'



update #MemoryManager
	set cntr_value = (select sum(cast(size_in_bytes as bigint))	/ 1024 from sys.dm_exec_cached_plans)
where	counter_name = 'Plan Cache'



-- total RAM on a server
declare @Total_RAM_on_a_server bigint
set @Total_RAM_on_a_server = (select physical_memory_kb from sys.dm_os_sys_info)

insert into #MemoryManager (counter_name, counter_location, counter_desc, cntr_value)
values ('Server Total RAM','sys.dm_os_sys_info (physical_memory_kb)','Total amount of RAM memory on a server machine',@Total_RAM_on_a_server)



-- calculate values in megabytes and gigabytes
update #MemoryManager
	set cntr_value_MB = cntr_value / 1024,
		cntr_value_GB = cast(cntr_value as decimal(16,2)) / 1024 / 1024




-- percentages calculation
if @ExpertMode = 1 begin

	declare 
		@Total_SQL_Server_Memory	bigint,
		@Target_Server_Memory		bigint

	set @Total_SQL_Server_Memory = (select cntr_value from #MemoryManager where counter_name = 'Total Server Memory')
	set @Target_Server_Memory = (select cntr_value from #MemoryManager where counter_name = 'Target Server Memory')


	update #MemoryManager
		set pct = 100,
			percentage_info = ''
	where	counter_name = 'Server Total RAM'


	-- target server memory 
	update #MemoryManager
		set pct = (cast(@Target_Server_Memory as decimal(16,2)) / cast(@Total_RAM_on_a_server as decimal(16,2))) * 100
	where	counter_name = 'Target Server Memory'

	update #MemoryManager
		set percentage_info = cast(pct as varchar) + '  %  of Total Server RAM'
	where	counter_name = 'Target Server Memory'


	-- total server memory
	update #MemoryManager
		set pct = (cast(@Total_SQL_Server_Memory as decimal(16,2)) / cast(@Target_Server_Memory as decimal(16,2))) * 100
	where	counter_name = 'Total Server Memory'

	update #MemoryManager
		set percentage_info = cast(pct as varchar) + '  %  of Target SQL Server Memory'
	where	counter_name = 'Total Server Memory'


	-- maximum workspace memory
	update #MemoryManager
		set pct = (cast(cntr_value as decimal(16,2)) / cast(@Target_Server_Memory as decimal(16,2))) * 100
	where	counter_name = 'Maximum Workspace Memory'

	update #MemoryManager
		set percentage_info = cast(pct as varchar) + '  %  of Target SQL Server Memory'
	where	counter_name = 'Maximum Workspace Memory'

	   
	-- other counters
	update #MemoryManager
		set pct = (cast(cntr_value as decimal(16,2)) / cast(@Total_SQL_Server_Memory as decimal(16,2))) * 100
	where pct is NULL

	update #MemoryManager
		set percentage_info = cast(pct as varchar) + '  %  of Total SQL Server Memory'
	where percentage_info is NULL

end



-- show collected data
if @ExpertMode = 0 begin

	select
		counter_name,
		counter_desc,
		cntr_value_MB			[MB],
		cntr_value_GB			[GB]
	from #MemoryManager
	order by cntr_value_MB desc

end


if @ExpertMode = 1 begin

	-- show break down of memory usage by SQL Server
	select
		counter_name,
		counter_location,
		counter_desc,
		cntr_value				[kb],
		cntr_value_MB			[MB],
		cntr_value_GB			[GB],
		percentage_info
	from #MemoryManager
	order by cntr_value_MB desc


	-- show memory clerks 
	select 
		[type]								[clerk_name], 
		case [type]
			when 'MEMORYCLERK_SQLBUFFERPOOL' then 'sys.dm_os_memory_clerks - Database Cache Memory (Buffer Pool)'
			else 'sys.dm_os_memory_clerks - part of the "Stolen Server Memory"'
		end [clerk_desc],
		sum(pages_kb)						[kb],
		sum(pages_kb) / 1024				[MB],
		sum(pages_kb) / 1024 / 1024			[GB]
	from sys.dm_os_memory_clerks
	group by [type]
	order by [kb] desc

	
end



end

