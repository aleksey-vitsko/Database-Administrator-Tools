

create or alter procedure MemoryManagerInfo (
	@ExpertMode			tinyint = 0)

as begin	

set nocount on

/***************************************************MEMORY MANAGER INFO PROCEDURE ********************************************************

Author: Aleksey Vitsko

Version: 1.07

Purpose: shows current performance counters for SQLServer:Memory Manager
(these show how much RAM memory is being used by SQL Server, and what for: database data cache, connections, locks, etc.)

History:

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
values	('Total Server Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Total amount of memory SQL Server is currently consuming'),
		('Target Server Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Total amount of memory SQL Server is allowed to consume (can be limited by "max server memory" setting)'),
		('Database Cache Memory','sys.dm_os_performance_counters - SQLServer:Memory Manager','Amount of memory SQL Server is currently using for cached database pages'),
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
		and [object_name] = 'SQLServer:Memory Manager'



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


	update #MemoryManager
		set pct = (cast(@Target_Server_Memory as decimal(16,2)) / cast(@Total_RAM_on_a_server as decimal(16,2))) * 100
	where	counter_name = 'Target Server Memory'

	update #MemoryManager
		set percentage_info = cast(pct as varchar) + '  %  of Total Server RAM'
	where	counter_name = 'Target Server Memory'


	update #MemoryManager
		set pct = (cast(@Total_SQL_Server_Memory as decimal(16,2)) / cast(@Target_Server_Memory as decimal(16,2))) * 100
	where	counter_name = 'Total Server Memory'

	update #MemoryManager
		set percentage_info = cast(pct as varchar) + '  %  of Target SQL Server Memory'
	where	counter_name = 'Total Server Memory'


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
		cntr_value_MB,
		cntr_value_GB
	from #MemoryManager
	order by cntr_value_MB desc

end


if @ExpertMode = 1 begin

	select
		counter_name,
		counter_location,
		counter_desc,
		cntr_value,
		cntr_value_MB,
		cntr_value_GB,
		percentage_info
	from #MemoryManager
	order by cntr_value_MB desc

end







/*

 select object_name, 
       counter_name, 
       instance_name, 
       cntr_value, 
       cntr_type
  from sys.dm_os_performance_counters
 where 1=1
   and [object_name] = 'SQLServer:Memory Manager'



		                                                                                               
select
	replace(counter_name,' (KB)','')	[counter_name],
	cntr_value / 1024					[MB]	
from sys.dm_os_performance_counters
where	[object_name] = 'SQLServer:Memory Manager'
		and counter_name not in ('External benefit of memory','Lock Blocks Allocated','Lock Owner Blocks Allocated','Lock Blocks','Lock Owner Blocks','Memory Grants Outstanding','Memory Grants Pending')
order by [MB] desc


*/


end

