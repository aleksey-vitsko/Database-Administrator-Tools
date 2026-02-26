

create or alter procedure ViewSessionsConnections (
	@Command				varchar(50) = 'all',
	@ExpertMode				tinyint = 0
	) 
	
as begin


/**************************************************** VIEW SESSIONS CONNECTIONS PROCEDURE ****************************************************

Author: Aleksey Vitsko

Version: 2.1.3


Description:

Use this SP to learn details about sessions connected to your instance.


History:

2026-02-26 - Aleksey Vitsko - added "db_user_names" column to output
2025-02-25 - Aleksey Vitsko - properly resolve database name for sessions with "Resource Database" database_id
2026-02-25 - Aleksey Vitsko - added "blocking_sql_text" column to output
2026-02-25 - Aleksey Vitsko - bugfix related to "memory grant" command mode
2026-02-23 - Aleksey Vitsko - added compatibility with SQL Server 2016-2017
2026-02-21 - Aleksey Vitsko - major rewrite of the stored procedure (version 2.0 released)

2022-08-11 - Aleksey Vitsko - added command "tempdb" (show only sessions that currently consume tempdb)
2022-08-11 - Aleksey Vitsko - added "tempdb_session_kb" and "tempdb_task_kb" columns (show tempdb consumption by session)
2022-08-10 - Aleksey Vitsko - added output mode "memory grant" (will show only sessions that have memory grants)
2022-08-10 - Aleksey Vitsko - added columns related to query memory grant information
2022-08-10 - Aleksey Vitsko - renamed "memory_usage" column to "memory_usage_pages", other cosmetic changes
2018-05-08 - Aleksey Vitsko - added support for db_user_name
2018-05-07 - Aleksey Vitsko - added support for blocking_sql_text 
2018-05-03 - Aleksey Vitsko - created procedure


Tested on:

- SQL Server 2016 (SP2), 2017 (RTM), 2019 (RTM), 2022 (RTM), 2025 (RTM)
- Azure SQL Managed Instance (SQL 2022 update policy)
- Azure SQL Database


Fast enough on SQL 2016-2025, SQL MI and SQL DB (vCore-based)
Can be slow on small DTU-based Azure SQL DBs (on first run)


***********************************************************************************************************************************************

Supported commands (@command parameter):

'all'									** show all sessions / connections (default)

'user'									** show only user sessions
'system'								** show only system sessions

'summary'								** show aggregate session counts by login

'executing','running'					** show sessions that are currently running / executing queries
'blocking','blocked'					** show sessions that are blocked

'open tran'								** show sessions that have open transaction(s)
'execute as','run as','impersonate'		** show sessions that have original login <> current login

'tempdb'								** show sessions that consume tempdb
'memory grant','memory grants'			** show sessions that hold memory grants


***********************************************************************************************************************************************/



	/* command parameter validation */

	if @Command not in ('all','user','system','summary','executing','running','blocking','blocked','open tran','execute as','run as','impersonate','tempdb','memory grant','memory grants') begin
		print 'Supplied command not supported!'
		print 'Supported commands:'
		print ''
		print '"all" - show all sessions / connections (default)

"user" -  show only user sessions
"system" - show only system sessions

"summary" - show aggregate session counts by login

"executing", "running" - show sessions that are currently running / executing queries
"blocking", "blocked" - show sessions that are blocked

"open tran" - show sessions that have open transaction(s)
"execute as", "run as", "impersonate" - show sessions that have original login <> current login

"tempdb" - show sessions that consume tempdb
"memory grant", "memory grants" - show sessions that hold memory grants'

	end




	/* determine database engine version */
	declare 
		@Version varchar(10),
		@EngineEdition int


		select @Version = 
			case
				when (select left(@@VERSION,30)) like '%2014%' then '2014'
				when (select left(@@VERSION,30)) like '%2016%' then '2016'
				when (select left(@@VERSION,30)) like '%2017%' then '2017'
				when (select left(@@VERSION,30)) like '%2019%' then '2019'
				when (select left(@@VERSION,30)) like '%2022%' then '2022'
				when (select left(@@VERSION,30)) like '%2025%' then '2025'
				when (select left(@@VERSION,30)) like '%SQL Azure%' then 'SQL Azure'
				else substring(@@VERSION,22,4)
		end


		set @EngineEdition = cast((select serverproperty('EngineEdition')) as int)



	/* SQL command */
	declare @SQL varchar(max)

	set @SQL = 'drop table if exists ##ViewSessionsConnections

	select 
		s.session_id,
		s.is_user_process,

		--s.database_id,
		case s.database_id 
			when 0 then ''''
			when 32765 then ''Resource Database''
			else db_name(s.database_id)					
		end												[database_name],

		s.login_name,
		s.original_login_name,
	
	
		sp.[type_desc]									[server_principal_type],
		--osp.[type_desc]								[original_principal_type],	

		--sp.principal_id								[server_principal_id],
		--osp.principal_id								[original_server_principal_id],

		s.security_id,
		--s.original_security_id,

		cast('''' as nvarchar(128))						[db_user_name],

		s.host_process_id,
		s.[host_name],
		s.[program_name],
		s.client_interface_name,
		--s.client_version								[TDS_protocol],				/*	TDS protocol version of the interface used by the client to connect to the server. The value is NULL for internal sessions. */
		s.nt_domain,
		s.nt_user_name,

		c.net_transport,
		c.protocol_type,
		c.auth_scheme,
		c.encrypt_option								[encrypted_connection],
		c.net_packet_size,

		c.client_net_address,
		c.client_tcp_port,
		c.local_net_address,
		c.local_tcp_port,
		--c.connection_id,
	
		s.endpoint_id,																
		e.[name]										[endpoint_name],
		e.[type_desc]									[endpoint_type],

		s.[status]										[status (session)],			/* Status of the session. Possible values: Running - Currently running one or more requests. Sleeping - Currently running no requests. Dormant - Session was reset because of connection pooling and is now in prelogin state. Preconnect - Session is in the Resource Governor classifier */
		r.[status]										[status (request)],			/* Status of the request. Can be one of the following values: background, rollback, running, runnable, sleeping, suspended */

		r.[command]										[command (request)],			/* Identifies the current type of command that is being processed. SELECT, INSERT, UPDATE, DELETE, BACKUP LOG, BACKUP DATABASE, DBCC, FOR */

		s.row_count										[row_count (session)],
		--r.row_count										[row_count (request)],		/* Number of rows that have been returned to the client by this request */

		s.open_transaction_count						[open_tran_count (session)],
		--r.open_transaction_count						[open_tran_count (request)],
		--r.open_resultset_count,
	
		s.prev_error									[last_error (session)],			/* ID of the last error returned on the session */
		--r.prev_error									[last_error (request)],			/* Last error that occurred during the execution of the request */

		--r.nest_level									[nest_level (request)],		/* Current nesting level of code that is executing on the request */

		--c.node_affinity,
	
		s.cpu_time										[cpu_time_ms (session)],			/* CPU time, in milliseconds, used by this session */
		r.cpu_time										[cpu_time_ms (request)],			/* CPU time in milliseconds that is used by the request */
	
		s.memory_usage * 8								[memory_kb (session)],			/* Number of 8-KB pages of memory used by this session. */	
		qmg.requested_memory_kb							[requested_memory_kb],		
		qmg.granted_memory_kb							[granted_memory_kb],															/* Total amount of memory actually granted in kilobytes */
		--qmg.used_memory_kb,															/* Physical memory used at this moment in kilobytes */
		--qmg.max_used_memory_kb,														/* Maximum physical memory used up to this moment in kilobytes */
		--qmg.query_cost,																/* Estimated query cost */

		isnull(ssu.[sum_tempdb_session_pages],0)						[tempdb_session_kb],
		isnull(tsu.[sum_tempdb_task_pages],0)							[tempdb_task_kb],

		s.reads											[reads (session)],					
		r.reads											[reads (request)],				/* Number of reads performed by this request */

		c.num_reads										[read_bytes (connection)],

		s.logical_reads									[logical_reads (session)],
		r.logical_reads									[logical_reads (request)],		/* Number of logical reads that have been performed by the request */

		--s.page_server_reads,
	
		c.num_writes									[write_bytes (connection)],

		s.writes										[writes (session)],
		r.writes										[writes (request)],
	
		
		--r.scheduler_id									[scheduler_id (request)],
		sch.cpu_id										[cpu_id (request)],

		--s.total_scheduled_time							[total_scheduled_time (session)],
	
		s.total_elapsed_time							[total_elapsed_time_ms (session)],									/* ? calculate as d:hh:mm:ss.ms ?  Time, in milliseconds, since the session was established */
		r.total_elapsed_time							[total_elapsed_time_ms (request)],				/* Total time elapsed in milliseconds since the request arrived */

	
		s.text_size,
		s.[language],
		s.date_format,
		s.date_first,

		s.quoted_identifier,
		s.arithabort,
		s.ansi_null_dflt_on,
		s.ansi_defaults,
		s.ansi_warnings,
		s.ansi_padding,
		s.ansi_nulls,
		s.concat_null_yields_null,
		s.lock_timeout,
		s.deadlock_priority,

		s.transaction_isolation_level,

		case s.transaction_isolation_level
			when 0 then ''Unspecified''
			when 1 then ''Read Uncommitted''
			when 2 then ''Read Committed''
			when 3 then ''Repeatable Read''
			when 4 then ''Serializable''
			when 5 then ''Snapshot''
		end													[transaction_isolation_level_desc],

		d.is_read_committed_snapshot_on,

		--s.group_id											[rg_group_id],			/* sys.resource_governor_workload_groups; pool_id, external_pool_id  */
		rgwg.[name]											[rg_workload_group],
		rgrp.[name]											[rg_resource_pool],

		db_name(s.authenticating_database_id)				[authenticating_database],

		c.connect_time,
		s.login_time,
	
		s.last_request_start_time,
		s.last_request_end_time,
	
	
		--r.[sql_handle],
		--r.[query_hash],
	
		--r.[plan_handle],
		--r.[query_plan_hash],


		r.wait_type											[current_wait],
		r.wait_time											[current_wait_time_ms],
		r.wait_resource										[current_wait_resource],
	
		r.transaction_id,
		tat.[name]											[transaction_name],
		case tat.transaction_type
			when 1 then ''Read/write''
			when 2 then ''Read-only''
			when 3 then ''System transaction''
			when 4 then ''Distributed transaction''
		end													[transaction_type],

		case tat.transaction_state
			when 0 then ''Not completely initialized''
			when 1 then ''Initialized but not started''
			when 2 then ''Active''
			when 3 then ''Ended, used for read-only tran''
			when 4 then ''Commit initialized (distr tran)''
			when 5 then ''Prepared state''
			when 6 then ''Committed''
			when 7 then ''Being rolled back''
			when 8 then ''Rolled back''
		end													[transaction_state],

		r.percent_complete,

		--r.dop												[request_dop],
		--r.parallel_worker_count,

		r.blocking_session_id,
		cast ('''' as nvarchar(128))							[blocking_login_name],

		t.[text]			[sql_text                                                                                             ],
		cast (NULL as nvarchar(max))							[blocking_sql_text]

	into ##ViewSessionsConnections
	from sys.dm_exec_sessions s

		left join sys.dm_exec_connections c on
			s.[session_id] = c.[session_id]

		left join sys.dm_exec_requests r on
			s.[session_id] = r.[session_id]

		left join sys.databases d on
			s.database_id = d.database_id

		left join sys.endpoints e on
			s.endpoint_id = e.endpoint_id

		left join sys.resource_governor_workload_groups rgwg on
			s.group_id = rgwg.group_id

		left join sys.resource_governor_resource_pools rgrp on
			rgwg.pool_id = rgrp.pool_id

		left join sys.dm_os_schedulers sch on
			r.scheduler_id = sch.scheduler_id

		left join (select 
					[session_id],
					sum((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count))		[sum_tempdb_session_pages]
				from sys.dm_db_session_space_usage
				where	((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count)) > 0
				group by [session_id]) ssu on

			s.[session_id] = ssu.[session_id]

		left join (select 
					[session_id],
					sum((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count))		[sum_tempdb_task_pages]
				from sys.dm_db_task_space_usage
				where	((user_objects_alloc_page_count - user_objects_dealloc_page_count) + (internal_objects_alloc_page_count - internal_objects_dealloc_page_count)) > 0
				group by [session_id]) tsu on
		
			s.[session_id] = tsu.[session_id]

		left join sys.dm_tran_active_transactions tat on
			r.transaction_id = tat.transaction_id

		left join sys.dm_exec_query_memory_grants qmg on
			s.[session_id] = qmg.[session_id]

		left join sys.server_principals osp on
			s.original_security_id = osp.[sid]

		left join sys.server_principals sp on
			s.security_id = sp.[sid]

		outer apply sys.dm_exec_sql_text (r.plan_handle) t'




	/* for Azure SQL Database */
	if @EngineEdition = 5 begin

		set @SQL = replace(@SQL,'s.endpoint_id,','')
	
		set @SQL = replace(@SQL,'e.[name]										[endpoint_name],','')

		set @SQL = replace(@SQL,'e.[type_desc]									[endpoint_type],','')

		set @SQL = replace(@SQL,'left join sys.endpoints e on','')

		set @SQL = replace(@SQL,'s.endpoint_id = e.endpoint_id','')

	end


	/* for SQL Server 2016-2017 */
	if @Version in ('2016','2017') begin

		set @SQL = replace(@SQL,'--s.page_server_reads,','')

	end



	/* in Expert mode, uncomment columns */
	if @ExpertMode = 1 begin

		set @SQL = replace(@SQL,'--','')

	end


	/* execute the command */
	exec (@SQL)




	/* get the database users */
	
	/* not in Azure SQL DB */
	if @EngineEdition <> 5 begin
	
		drop table if exists #Databases 

		create table #Databases (
			RowID					int primary key identity,
			[Database_Name]			nvarchar(128),	
			SQL_Query				nvarchar(max)
			)

		insert into #Databases ([Database_Name])
		select 
			distinct [database_name]
		from ##ViewSessionsConnections 
		where [database_name] <> ''
		order by [database_name]

		update #Databases
			set SQL_Query = 'update ##ViewSessionsConnections set db_user_name = dp.[name] from ##ViewSessionsConnections join [' + [Database_Name] + '].sys.database_principals dp on security_id = sid where [database_name] = ''' + [Database_Name] + ''''

		declare @i int = 1

		while @i <= (select max(RowID) from #Databases) begin

			set @SQL = (select SQL_Query from #Databases where RowID = @i)

			exec(@SQL)

			set @i = @i + 1

		end

	end


	/* in Azure SQL DB */
	if @EngineEdition = 5 begin
		
		update ##ViewSessionsConnections 
			set db_user_name = dp.[name] 
		from ##ViewSessionsConnections 
			join sys.database_principals dp on 
				security_id = sid

	end


	update ##ViewSessionsConnections
		set db_user_name = 'dbo'
	where	[database_name] not in ('','Resource Database')
			and login_name = 'sa'
			and db_user_name = ''


		

	/*
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

	*/




	/* resolve blocking login names or reasons */
	update blocked
		set blocked.blocking_login_name = isnull(blocking.login_name,'')
	from ##ViewSessionsConnections blocked

		join ##ViewSessionsConnections blocking on
			blocked.blocking_session_id = blocking.[session_id]

	where	blocked.blocking_session_id is not NULL
			and blocked.blocking_session_id <> 0

	
	update ##ViewSessionsConnections
		set blocking_login_name = 
			case 
				when blocking_session_id = -2 then 'Orphaned distributed transaction'
				when blocking_session_id = -3 then 'Deferred recovery transaction'
				when blocking_session_id = -4 then 'Session_id of the blocking latch owner couldnt be determined at this time because of internal latch state transitions'
				when blocking_session_id = -5 then 'Session is waiting on an asynchronous action to complete'
			end
	where	blocking_session_id < 0


	/* blocking sql text */
	update main 
		set main.blocking_sql_text = blocking.sql_text 
	from ##ViewSessionsConnections main
		left join ##ViewSessionsConnections blocking on
			main.blocking_session_id = blocking.[session_id]



	/*************************************************************** Show Data ***************************************************************/

	/* show summary */
	if @Command = 'summary' begin
	
		/* totals by system and user */
		select 
			(select count(*) from ##ViewSessionsConnections where is_user_process = 0)		[system_session_count],
			(select count(*) from ##ViewSessionsConnections where is_user_process = 1)		[user_session_count]
	
		/* total by login */
		select 
			case is_user_process
				when 0 then 'System'
				when 1 then 'User'
			end	[type],
			[database_name],
			login_name,
			count(*)		[session_count]
		from ##ViewSessionsConnections
		group by 
			case is_user_process
				when 0 then 'System'
				when 1 then 'User'
			end,
			[database_name],
			login_name
		order by [type], [database_name], [session_count] desc

	end




	if @command not in ('summary') begin

		/* filter rows based on command parameter */
	
		
		if @command = 'all' begin
			select * from ##ViewSessionsConnections
		end


		if @Command = 'user' begin
			select * from ##ViewSessionsConnections 
			where is_user_process = 1
		end

		if @Command = 'system' begin
			select * from ##ViewSessionsConnections 
			where is_user_process = 0
		end

		
		if @command in ('executing','running') begin
			select * from ##ViewSessionsConnections
			where sql_text is not NULL
		end




		if @command in ('tempdb') begin
			select * from ##ViewSessionsConnections 
			where	tempdb_session_kb > 0
					or tempdb_task_kb > 0
		end


		
		if @command in ('memory grant','memory grants') begin
			select * from ##ViewSessionsConnections 
			where granted_memory_kb is not NULL
			order by granted_memory_kb desc
		end


		
		-- view all sessions that use impersonation / execute as
		if @command in ('execute as','run as','impersonate') begin
			select * from ##ViewSessionsConnections
			where	login_name <> original_login_name
		end


		if @command in ('open tran') begin
			select * from ##ViewSessionsConnections
			where	[open_tran_count (session)] > 0
			order by [open_tran_count (session)] desc
		end


		
		if @command in ('blocking','blocked') begin
			select * from ##ViewSessionsConnections
			where	blocking_session_id > 0
		end

						
	end

	

	/* clean up */
	drop table if exists ##ViewSessionsConnections



		 
		 
	
/* 

exec ViewSessionsConnections

exec ViewSessionsConnections @ExpertMode = 1


exec ViewSessionsConnections @command = 'summary'

exec ViewSessionsConnections @command = 'user'

exec ViewSessionsConnections @command = 'system'



exec ViewSessionsConnections @command = 'running'

exec ViewSessionsConnections @command = 'blocking'

exec ViewSessionsConnections @command = 'run as'

exec ViewSessionsConnections @command = 'tempdb'

exec ViewSessionsConnections @command = 'memory grant'

exec ViewSessionsConnections @command = 'open tran'



exec ViewSessionsConnections @command = 'bla bla'






select * from sys.dm_exec_requests


select * from sys.server_principals


select * from sys.database_principals


select * from sys.dm_exec_sessions 
where database_id = 0


select * from sys.databases


select * from sys.sysprocesses where spid in (86,103,98,91,96,170)


select * from sys.database_principals where sid = 0x010100000000000512000000



*/









end


