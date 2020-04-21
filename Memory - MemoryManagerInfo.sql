

        
create or alter procedure MemoryManagerInfo as begin	

set nocount on


/***************************************************MEMORY MANAGER INFO PROCEDURE ********************************************************

Author: Aleksey Vitsko

Version: 1.01

Purpose: shows current performance counters for SQLServer:Memory Manager
(these show how much RAM memory is being used by SQL Server, and what for: database data cache, connections, locks, etc.)

History:

2019-11-05 --> Aleksey Vitsko - added "Plan Cache" memory info
2019-11-01 --> Aleksey Vitsko - created procedure


***************************************************************************************************************************************/


-- use temp table
if object_id('TempDB..#MemoryManager') is not NULL begin drop table #MemoryManager end

create table #MemoryManager (
	ID					int identity primary key,
	counter_name		varchar(100),
	counter_desc		varchar(500),
	cntr_value			bigint,
	cntr_value_MB		bigint,
	cntr_value_GB		decimal(8,2)
	)


-- insert memory manager performance counter names with descriptions
insert into #MemoryManager (counter_name, counter_desc)
values	('Total Server Memory','Total amount of dynamic memory the server is currently consuming'),
		('Target Server Memory','Ideal amount of memory the server is willing to consume (can be limited by "max server memory" setting)'),
		('Database Cache Memory','Amount of memory the server is currently using for the database cache'),
		('Maximum Workspace Memory','Total amount of memory available for grants to executing processes. This memory is used primarily for hash, sort and create index operations'),
		('Stolen Server Memory','Amount of memory the server is currently using for the purposes other than the database pages'),
		('Lock Memory','Total amount of dynamic memory the server is using for locks'),
		('Free Memory','Amount of memory the server is currently not using.'),
		('Log Pool Memory','Total amount of dynamic memory the server is using for Log Pool'),
		('SQL Cache Memory','Total amount of dynamic memory the server is using for the dynamic SQL cache'),
		('Connection Memory','Total amount of dynamic memory the server is using for maintaining connections'),
		('Optimizer Memory','Total amount of dynamic memory the server is using for query optimization'),
		('Reserved Server Memory','Amount of memory the server has reserved for future usage. This counter shows current unused amount of the initial grant shown in Granted Workspace Memory'),
		('Granted Workspace Memory','Total amount of memory granted to executing processes. This memory is used for hash, sort and create index operations'),
		('Plan Cache','This is where SQL Server caches query execution plans it has run')


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



-- calculate values in megabytes and gigabytes
update #MemoryManager
	set cntr_value_MB = cntr_value / 1024,
		cntr_value_GB = cntr_value / 1024 / 1024



-- show collected data
select
	counter_name,
	counter_desc,
	cntr_value_MB,
	cntr_value_GB 
from #MemoryManager
order by cntr_value_MB desc








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

