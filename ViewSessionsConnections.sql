

create or alter procedure ViewSessionsConnections (@command varchar(100) = 'all') as begin


/********************************************* INFO *******************************************

Author: Aleksey Vitsko
Created: May 2018


--------------------------------------------------------------------------------------------------------------------------

Accepts arguments (@command):

'all'									-- show all sessions / connections (default)

'executing','running'					-- show user sessions that are currently running / executing queries
'blocking','blocked'					-- show sessions that are blocked / cause blocking

'user'									-- show only user sessions
'system'								-- show only system sessions

'open tran'								-- show sessions that have open transaction
'execute as','run as','impersonate'		-- show sessions that have original login <> current login

'memory grant','memory grants'			-- show sessions that have memory grants
'tempdb'								-- show sessions that currently consume tempdb

'summary'								-- show aggregate session counts by login


--------------------------------------------------------------------------------------------------------------------------

Version: 1.14

Change history:

2022-08-11 - Aleksey Vitsko - added command "tempdb" (show only sessions that currently consume tempdb)
2022-08-11 - Aleksey Vitsko - added "tempdb_session_kb" and "tempdb_task_kb" columns (show tempdb consumption by session)
2022-08-10 - Aleksey Vitsko - added output mode "memory grant" (will show only sessions that have memory grants)
2022-08-10 - Aleksey Vitsko - added columns related to query memory grant information
2022-08-10 - Aleksey Vitsko - renamed "memory_usage" column to "memory_usage_pages", other cosmetic changes
2018-05-08 - Aleksey Vitsko - added support for db_user_name
2018-05-07 - Aleksey Vitsko - added support for blocking_sql_text 
2018-05-03 - Aleksey Vitsko - created procedure


******************************************************************************************/



-- get session list
if object_id ('tempdb..#SessionsConnections') is not null drop table #SessionsConnections

create table #SessionsConnections (
	session_id							smallint,				-- sys.dm_exec_sessions
	kpid								smallint,				-- sys.sysprocesses (windows thread id)
	
	database_id							int,					-- sys.dm_exec_sessions
	[db_name]							varchar(150),			-- sys.databases
	
	is_user_process						bit,					-- sys.dm_exec_sessions
	[host_name]							nvarchar(128),			-- sys.dm_exec_sessions
	host_process_id						int,
	[program_name]						nvarchar(128),			-- sys.dm_exec_sessions
	client_interface_name				nvarchar(32),			-- sys.dm_exec_sessions

	nt_domain							nvarchar(128),			-- sys.dm_exec_sessions
	nt_user_name						nvarchar(128),			-- sys.dm_exec_sessions
	login_name							nvarchar(128),			-- sys.dm_exec_sessions
	original_login_name					nvarchar(128),			-- sys.dm_exec_sessions
	security_id							varbinary(85),			-- sys.dm_exec_sessions
	original_security_id				varbinary(85),			-- sys.dm_exec_sessions

	connect_time						datetime,				-- connections
	login_time							datetime,				-- sys.dm_exec_sessions
	[status]							nvarchar(30),			-- sys.dm_exec_sessions
	[language]							nvarchar(128),			-- sys.dm_exec_sessions

	cmd									nvarchar(32),			-- sys.sysprocesses
	command								nvarchar(32),			-- exec_requests
	[user_id]							int,					-- exec_requests
	[uid]								int,					-- sys.sysprocesses
	db_user_name						nvarchar(128),			-- sys.users
	blocking_session_id					smallint,				-- exec_requests
	blocked								smallint,				-- sys.sysprocesses
	percent_complete					real,					-- exec_requests
	estimated_completion_time			bigint,					-- exec_requests

	con_session_id						int,					-- connections
	most_recent_session_id				int,					-- connections
	connection_id						uniqueidentifier,		-- connections
	net_transport						nvarchar(40),			-- connections
	protocol_type						nvarchar(40),			-- connections
	auth_scheme							nvarchar(40),			-- connections
	net_library							nchar(12),				-- sys.sysprocesses

	client_net_address					varchar(48),			-- connections
	client_tcp_port						int,					-- connections
	local_net_address					varchar(48),			-- connections
	local_tcp_port						int,					-- connections

	cpu_time							int,					-- sys.dm_exec_sessions
	memory_usage_pages					int,					-- sys.dm_exec_sessions					-- Number of 8-KB pages of memory used by this session.
	
	requested_memory_kb					bigint,					-- sys.dm_exec_query_memory_grants		-- Total requested amount of memory in kilobytes.
	granted_memory_kb					bigint,					-- sys.dm_exec_query_memory_grants		-- Total amount of memory actually granted in kilobytes. Can be NULL if the memory is not granted yet.
	used_memory_kb 						bigint, 				-- sys.dm_exec_query_memory_grants		-- Physical memory used at this moment in kilobytes.
	max_used_memory_kb					bigint,					-- sys.dm_exec_query_memory_grants		-- Maximum physical memory used up to this moment in kilobytes.

	tempdb_session_kb					bigint,					-- sys.dm_db_session_space_usage		-- (((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count)) * 8) > 0
	tempdb_task_kb						bigint,					-- sys.dm_db_task_space_usage			-- (((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count)) * 8) > 0

	reads								bigint,					-- sys.dm_exec_sessions
	writes								bigint,					-- sys.dm_exec_sessions
	logical_reads						bigint,					-- sys.dm_exec_sessions
	
	[deadlock_priority]					int,					-- sys.dm_exec_sessions
	open_transaction_count				int,					-- sys.dm_exec_sessions
	row_count							bigint,					-- sys.dm_exec_sessions
	transaction_isolation_level_id		smallint,				-- 0 = Unspecified 1 = ReadUncommitted 2 = ReadCommitted 3 = Repeatable 4 = Serializable 5 = Snapshot
	transaction_isolation_level			varchar(50),			

	total_scheduled_time				int,					-- sys.dm_exec_sessions
	total_elapsed_time					int,					-- sys.dm_exec_sessions

	last_request_start_time				datetime,				-- sys.dm_exec_sessions
	last_request_end_time				datetime,				-- sys.dm_exec_sessions

	wait_type							nvarchar(60),			-- exec_requests
	wait_time							int,					-- exec_requests
	wait_resource						nvarchar(256),			-- exec_requests
	last_wait_type						nvarchar(60),			-- exec_requests

	[sql_handle]						varbinary(64),			-- exec_requests
	most_recent_sql_handle				varbinary(64),			-- connections
	sql_text							nvarchar(max) default '',			-- dm_exec_sql_text
	most_recent_sql_text				nvarchar(max) default '',			-- dm_exec_sql_text
	blocking_sql_text					nvarchar(max) default ''	
)


-- clustered index on session ID (not primary key because there might be NULLs)
create clustered index CIX_Session_ID on #SessionsConnections (session_id)



-- get sessions
insert into #SessionsConnections (session_id, database_id, is_user_process, [host_name], host_process_id, [program_name], client_interface_name, nt_domain, nt_user_name, login_name, security_id, original_security_id,
original_login_name, login_time, [status], [language],cpu_time, memory_usage_pages, reads, writes, logical_reads, [deadlock_priority], open_transaction_count, row_count, transaction_isolation_level_id, total_scheduled_time,
	total_elapsed_time, last_request_start_time, last_request_end_time)
select 
	session_id, 
	database_id, 
	is_user_process, 
	[host_name], 
	host_process_id, 
	[program_name],
	client_interface_name, 
	nt_domain, 
	nt_user_name, 
	login_name, 
	security_id, 
	original_security_id,
	original_login_name, 
	login_time, 
	[status], 
	[language],
	cpu_time, 
	memory_usage, 
	reads, 
	writes, 
	logical_reads, 
	[deadlock_priority], 
	open_transaction_count, 
	row_count, 
	transaction_isolation_level, 
	total_scheduled_time,
	total_elapsed_time, 
	last_request_start_time, 
	last_request_end_time 
from sys.dm_exec_sessions




-- get memory grant info
update s
	set s.requested_memory_kb = g.requested_memory_kb,		
		s.granted_memory_kb = g.granted_memory_kb,			
		s.used_memory_kb = g.used_memory_kb,			
		s.max_used_memory_kb = g.max_used_memory_kb
from #SessionsConnections s
	join sys.dm_exec_query_memory_grants g on
		s.session_id = g.session_id



-- if command is "memory grant", delete other sessions from sp output
if @command in ('memory grant','memory grants') begin
	delete from #SessionsConnections 
	where requested_memory_kb is NULL
end



-- get tempdb usage by session 
update s
	set tempdb_session_kb = ((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count)) * 8
from #SessionsConnections s
	join sys.dm_db_session_space_usage ssu on
		s.session_id = ssu.session_id
		and ((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count)) > 0


-- get tempdb usage by task / session 
update s
	set tempdb_task_kb = [sum_tempdb_task_pages] * 8
from #SessionsConnections s
	join	(select 
				session_id,
				sum((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count))		[sum_tempdb_task_pages]
			from sys.dm_db_task_space_usage
			where	((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count)) > 0
			group by session_id) tsu on
		
		s.session_id = tsu.session_id


-- if command is "memory grant", delete other sessions from sp output
if @command in ('tempdb') begin
	delete from #SessionsConnections 
	where	tempdb_session_kb is NULL
			and tempdb_task_kb is NULL
end





-- get sys processes info
update sc 
	set sc.kpid = p.kpid,
		sc.[uid] = p.[uid],
		sc.net_library = p.net_library,
		sc.cmd = p.cmd,
		sc.blocked = p.blocked
from #SessionsConnections sc
	join sys.sysprocesses p on
		session_id = spid


-- get database name
update sc
	set [db_name] = d.[name]
from #SessionsConnections sc
	join sys.databases d on 
		sc.database_id = d.database_id



-- get database users
begin try
	exec sp_MSforeachdb 'USE [?]; update #SessionsConnections set db_user_name = [name] from #SessionsConnections join sys.database_principals on [uid] = principal_id where [db_name] = db_name()'
end try

begin catch
	update #SessionsConnections 
		set db_user_name = [name] 
	from #SessionsConnections 
		join sys.database_principals on 
			[uid] = principal_id 
	where [db_name] = db_name()
end catch


update #SessionsConnections
	set db_user_name = 'dbo'
where	original_login_name = 'sa'
		and db_user_name is NULL



-- transaction isolation level
update #SessionsConnections
	set transaction_isolation_level = case transaction_isolation_level_id
			when 0 then 'Unspecified'
			when 1 then 'Read Uncommitted'
			when 2 then 'Read Committed'
			when 3 then 'Repeatable'
			when 4 then 'Serializable'
			when 5 then 'Snapshot'
		end
		 

	
-- get executing requests info
update sc
	set sc.command = r.command,
		sc.[user_id] = r.[user_id],
		sc.blocking_session_id = r.blocking_session_id,
		sc.percent_complete = r.percent_complete,
		sc.estimated_completion_time = r.estimated_completion_time,
		sc.wait_type = r.wait_type,
		sc.wait_time = r.wait_time,
		sc.wait_resource = r.wait_resource,
		sc.last_wait_type = r.last_wait_type,
		sc.[sql_handle] = r.[sql_handle]
		
from #SessionsConnections sc
	join sys.dm_exec_requests r on
		sc.session_id = r.session_id

		
		
-- get connections info
update sc
	set sc.con_session_id = c.session_id,
		sc.most_recent_session_id = c.most_recent_session_id,
		sc.connection_id = c.connection_id,
		sc.connect_time = c.connect_time,
		sc.net_transport = c.net_transport,
		sc.protocol_type = c.protocol_type,
		sc.auth_scheme = c.auth_scheme,
		sc.client_net_address = c.client_net_address,
		sc.client_tcp_port = c.client_tcp_port,
		sc.local_net_address = c.local_net_address,
		sc.local_tcp_port = c.local_tcp_port,
		sc.most_recent_sql_handle = c.most_recent_sql_handle
from #SessionsConnections sc
	join sys.dm_exec_connections c on
		sc.session_id = c.session_id



-- get current executing sql text
update #SessionsConnections
	set sql_text = [text]
from #SessionsConnections
	cross apply sys.dm_exec_sql_text([sql_handle])


-- get most recent executed sql text
update #SessionsConnections
	set most_recent_sql_text = [text]
from #SessionsConnections
	cross apply sys.dm_exec_sql_text([most_recent_sql_handle])


-- get blocking sql text 
update sc
	set sc.blocking_sql_text = sc2.most_recent_sql_text
from #SessionsConnections sc
	join #SessionsConnections sc2 on
		sc.blocking_session_id = sc2.session_id





-- get connections without sessions
insert into #SessionsConnections (connect_time,	net_transport, protocol_type, auth_scheme, client_net_address, client_tcp_port, local_net_address, local_tcp_port, connection_id, most_recent_sql_handle)
select 
	connect_time,
	net_transport,
	protocol_type,
	auth_scheme,
	client_net_address,
	client_tcp_port,
	local_net_address,
	local_tcp_port,
	connection_id,
	most_recent_sql_handle
from sys.dm_exec_connections
where session_id is NULL



-- mark system connections
update #SessionsConnections
	set is_user_process = 0
where is_user_process is NULL


-- update blocking/blocked info
update #SessionsConnections
	set blocked = 0
where blocked is NULL

update #SessionsConnections
	set blocking_session_id = 0
where blocking_session_id is NULL




------------------------------------------------------ Show Data --------------------------------------------------------

-- view all sessions / connections
if @command = 'all' begin
	
	select * from #SessionsConnections
	order by db_name, database_id, is_user_process, login_name

end


-- view sessions / connections that are currently executing queries
if @command in ('executing','running') begin
	
	select * from #SessionsConnections
	where sql_text <> ''
	order by db_name, database_id, is_user_process, login_name

end


-- view all sessions that cause blocking
if @command in ('blocking','blocked') begin
	
	select * from #SessionsConnections
	where	(blocked <> 0) 
			or (blocking_session_id <> 0)
			or session_id in (select blocked from #SessionsConnections where blocked <> 0)
			or session_id in (select blocked from #SessionsConnections where blocking_session_id <> 0)
	order by db_name, database_id, is_user_process, login_name

end



-- view all sessions that use impersonation / execute as
if @command in ('execute as','run as','impersonate') begin
	
	select * from #SessionsConnections
	where	login_name <> original_login_name
			or security_id <> original_security_id
	order by db_name, database_id, is_user_process, login_name

end


-- view only user sessions 
if @command in ('user') begin
	
	select * from #SessionsConnections
	where	is_user_process = 1
	order by db_name, database_id, is_user_process, login_name

end


-- view only system sessions 
if @command in ('system') begin
	
	select * from #SessionsConnections
	where	is_user_process = 0
	order by db_name, database_id, is_user_process, login_name

end



-- view open transaction count > 0 sessions 
if @command in ('open tran') begin
	
	select * from #SessionsConnections
	where	open_transaction_count > 0
	order by db_name, database_id, is_user_process, login_name

end



-- view memory grant info
if @command in ('memory grant','memory grants') begin
	
	select * from #SessionsConnections
	where	requested_memory_kb is not NULL
	order by requested_memory_kb desc
	--order by db_name, database_id, is_user_process, login_name

end



-- view tempdb consumption
if @command in ('tempdb') begin
	
	select * from #SessionsConnections
	where	tempdb_session_kb is not NULL
			or tempdb_task_kb is not NULL
	order by tempdb_session_kb desc, tempdb_task_kb desc
	
end






-- view summary info 
if @command in ('summary') begin
	
	-- totals by system and user
	select 
		(select count(*) from #SessionsConnections where is_user_process = 0)		[System Processes],
		(select count(*) from #SessionsConnections where is_user_process = 1)		[User Processes]
	
	-- total by login
	select 
		case is_user_process
			when 0 then 'System'
			when 1 then 'User'
		end	[Type],
		[db_name],
		login_name,
		count(*)		[Process Count]
	from #SessionsConnections
	group by case is_user_process
			when 0 then 'System'
			when 1 then 'User'
		end,
		[db_name],
		login_name
	order by [Type], [db_name], [Process Count] desc

end



	
-- select * from sys.dm_exec_connections




-- select * from sys.sysprocesses	
	
	
-- select * from sys.dm_exec_connections




end


