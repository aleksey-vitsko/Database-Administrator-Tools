
create or alter procedure ViewRunningJobs (
	@Detailed		tinyint = 0								/* if set to 1, returns more columns */
	)
as begin

/****************************************************************** VIEW RUNNING JOBS PROCEDURE **************************************************************

Author: Aleksey Vitsko

Version: 1.00


Description: 

Shows currently running jobs along with steps executed.

History:

2025-11-18 --> Aleksey Vitsko - created procedure 



Tested on:

- SQL Server 2016 (SP2), 2017 (CU31), 2019 (RTM), 2022 (RTM), 2025 
- Azure SQL Managed Instance (SQL 2022 and 2025 update policy)


*****************************************************************************************************************************************************************/

set nocount on


/* not detailed */

if @Detailed = 0 begin

	select 
		CONCAT(
		RIGHT('00' + CAST(DATEDIFF(MILLISECOND, start_execution_date, getdate()) / (1000 * 60 * 60 * 24) AS VARCHAR), 2), ' ',
		RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60) AS VARCHAR), 2), ':',
		RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60 * 60)) / (1000 * 60) AS VARCHAR), 2), ':',
		RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60)) / 1000 AS VARCHAR), 2), '.',
		RIGHT('000' + CAST(DATEDIFF(MILLISECOND, start_execution_date, getdate()) % 1000 AS VARCHAR), 3)
	) AS [total_job_duration],

		jv.[name]						[job_name],
		[description],

		/*	jv.job_id,
		originating_server,	*/

		[enabled],

		ja.[session_id],
		/*	s.login_name, */
		s.original_login_name,
		
		/*	owner_sid, */
		sp.[name]						[owner],
	
		start_step_id,

		/*	jv.category_id, */
		cat.[name]						[category_name],
		
		/*	category_class, */
		case category_class
				when 1 then 'Job'
				when 1 then 'Alert'
				when 1 then 'Operator'
		end								[category_class_desc],
	
		/*	category_type, */
		case category_type
				when 1 then 'Local'
				when 1 then 'Multiserver'
				when 1 then 'None'
		end								[category_type_desc],
	
		/*	run_requested_source, */
		case run_requested_source
			when 1 then 'Source_Scheduler'
			when 2 then 'Source_Alerter' 
			when 3 then 'Source_Boot'
			when 4 then 'Source_User'
			when 6 then 'Source_On_Idle_Schedule'
		end								[run_requested_source_desc],

		run_requested_date,
		start_execution_date,
		stop_execution_date,

		last_executed_step_id,
		last_executed_step_date,

		case previous_step.last_run_outcome 
			when 0 then 'Failed'
			when 1 then 'Succeeded'
			when 2 then 'Retry'
			when 3 then 'Cancelled'
			when 5 then 'Unknown'
		end [last_executed_step_outcome],
  

		current_step.[step_id]				[current_step_id],

		current_step.step_name				[current_step_name],
		current_step.subsystem				[current_step_subsystem],
		current_step.command				[current_step_command],

		case current_step.on_success_action 
			when 1 then 'Quit with success'
			when 2 then 'Quit with failure'
			when 3 then 'Go to next step'
			when 4 then 'Go to step on_success_step_id'
		end [current_step_on_success_action],

		/*	current_step.on_success_step_id		[current_step_on_success_step_id], */

		case current_step.on_fail_action 
			when 1 then 'Quit with success'
			when 2 then 'Quit with failure'
			when 3 then 'Go to next step'
			when 4 then 'Go to step on_fail_step_id'
		end [current_step_on_fail_action],

		current_step.[database_name]		[current_step_database_name],

		/*	current_step.retry_attempts			[current_step_retry_attempts],
		current_step.retry_interval			[current_step_retry_interval],
		current_step.output_file_name		[current_step_output_file_name], */

		case
			when last_executed_step_id is NULL then 
											CONCAT(
												RIGHT('00' + CAST(DATEDIFF(MILLISECOND, start_execution_date, getdate()) / (1000 * 60 * 60 * 24) AS VARCHAR), 2), ' ',
												RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60) AS VARCHAR), 2), ':',
												RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60 * 60)) / (1000 * 60) AS VARCHAR), 2), ':',
												RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60)) / 1000 AS VARCHAR), 2), '.',
												RIGHT('000' + CAST(DATEDIFF(MILLISECOND, start_execution_date, getdate()) % 1000 AS VARCHAR), 3)
											) 
			when last_executed_step_id is not NULL then 
											CONCAT(
												RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) / (1000 * 60 * 60 * 24) AS VARCHAR), 2), ' ',
												RIGHT('00' + CAST(((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60) AS VARCHAR), 2), ':',
												RIGHT('00' + CAST(((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) % (1000 * 60 * 60)) / (1000 * 60) AS VARCHAR), 2), ':',
												RIGHT('00' + CAST(((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) % (1000 * 60)) / 1000 AS VARCHAR), 2), '.',
												RIGHT('000' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) % 1000 AS VARCHAR), 3)
											) 

		end [current_step_duration]

	   
	from msdb.dbo.sysjobs_view jv
	
		left join msdb.dbo.syscategories  cat on
			jv.category_id = cat.category_id
	
		left join sys.server_principals sp on
			owner_sid = [sid]
	
		join msdb.dbo.sysjobactivity ja on
			jv.job_id = ja.job_id
			and run_requested_date is not NULL
			and stop_execution_date is NULL	
			and ja.session_id = (SELECT session_id FROM msdb.dbo.syssessions where agent_start_date = (select max(agent_start_date) from msdb.dbo.syssessions))


		left join msdb.dbo.sysjobsteps previous_step on
			ja.job_id = previous_step.job_id
			and ja.last_executed_step_id = previous_step.step_id


		left join msdb.dbo.sysjobsteps current_step on
			ja.job_id = current_step.job_id
			and coalesce(ja.last_executed_step_id + 1,isnull(last_executed_step_id,1)) = current_step.step_id

					 
		cross apply (select 
						sum((last_run_duration / 10000) * 3600 +			/* hours to seconds */
						((last_run_duration % 10000) / 100) * 60 +			/* minutes to seconds */
						(last_run_duration % 100)
						) * 1000		[sum_last_step_run_ms]
					from msdb.dbo.sysjobsteps
					where	step_id <= previous_step.step_id
							and job_id = jv.job_id
						) sum_previous_steps_duration

		left join sys.dm_exec_sessions s on
			ja.[session_id] = s.[session_id]

	order by [total_job_duration] desc


end





/* detailed */

if @Detailed = 1 begin

	select 
		CONCAT(
		RIGHT('00' + CAST(DATEDIFF(MILLISECOND, start_execution_date, getdate()) / (1000 * 60 * 60 * 24) AS VARCHAR), 2), ' ',
		RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60) AS VARCHAR), 2), ':',
		RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60 * 60)) / (1000 * 60) AS VARCHAR), 2), ':',
		RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60)) / 1000 AS VARCHAR), 2), '.',
		RIGHT('000' + CAST(DATEDIFF(MILLISECOND, start_execution_date, getdate()) % 1000 AS VARCHAR), 3)
	) AS [total_job_duration],

		jv.[name]						[job_name],
		[description],

		jv.job_id,
		originating_server,

		[enabled],

		ja.[session_id],
		s.login_name,
		s.original_login_name,
		
		owner_sid,
		sp.[name]						[owner],
	
		start_step_id,

		jv.category_id,
		cat.[name]						[category_name],
		category_class,
		case category_class
				when 1 then 'Job'
				when 1 then 'Alert'
				when 1 then 'Operator'
		end								[category_class_desc],
	
		category_type,
		case category_type
				when 1 then 'Local'
				when 1 then 'Multiserver'
				when 1 then 'None'
		end								[category_type_desc],
	
		run_requested_source,
		case run_requested_source
			when 1 then 'Source_Scheduler'
			when 2 then 'Source_Alerter' 
			when 3 then 'Source_Boot'
			when 4 then 'Source_User'
			when 6 then 'Source_On_Idle_Schedule'
		end								[run_requested_source_desc],

		run_requested_date,
		start_execution_date,
		stop_execution_date,

		last_executed_step_id,
		last_executed_step_date,

		case previous_step.last_run_outcome 
			when 0 then 'Failed'
			when 1 then 'Succeeded'
			when 2 then 'Retry'
			when 3 then 'Cancelled'
			when 5 then 'Unknown'
		end [last_executed_step_outcome],

		current_step.[step_id]				[current_step_id],

		current_step.step_name				[current_step_name],
		current_step.subsystem				[current_step_subsystem],
		current_step.command				[current_step_command],

		case current_step.on_success_action 
			when 1 then 'Quit with success'
			when 2 then 'Quit with failure'
			when 3 then 'Go to next step'
			when 4 then 'Go to step on_success_step_id'
		end [current_step_on_success_action],

		current_step.on_success_step_id		[current_step_on_success_step_id],

		case current_step.on_fail_action 
			when 1 then 'Quit with success'
			when 2 then 'Quit with failure'
			when 3 then 'Go to next step'
			when 4 then 'Go to step on_fail_step_id'
		end [current_step_on_fail_action],

		current_step.[database_name]		[current_step_database_name],

		current_step.retry_attempts			[current_step_retry_attempts],
		current_step.retry_interval			[current_step_retry_interval],
		current_step.output_file_name		[current_step_output_file_name],

		case
			when last_executed_step_id is NULL then 
											CONCAT(
												RIGHT('00' + CAST(DATEDIFF(MILLISECOND, start_execution_date, getdate()) / (1000 * 60 * 60 * 24) AS VARCHAR), 2), ' ',
												RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60) AS VARCHAR), 2), ':',
												RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60 * 60)) / (1000 * 60) AS VARCHAR), 2), ':',
												RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) % (1000 * 60)) / 1000 AS VARCHAR), 2), '.',
												RIGHT('000' + CAST(DATEDIFF(MILLISECOND, start_execution_date, getdate()) % 1000 AS VARCHAR), 3)
											) 
			when last_executed_step_id is not NULL then 
											CONCAT(
												RIGHT('00' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) / (1000 * 60 * 60 * 24) AS VARCHAR), 2), ' ',
												RIGHT('00' + CAST(((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60) AS VARCHAR), 2), ':',
												RIGHT('00' + CAST(((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) % (1000 * 60 * 60)) / (1000 * 60) AS VARCHAR), 2), ':',
												RIGHT('00' + CAST(((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) % (1000 * 60)) / 1000 AS VARCHAR), 2), '.',
												RIGHT('000' + CAST((DATEDIFF(MILLISECOND, start_execution_date, getdate()) - [sum_last_step_run_ms]) % 1000 AS VARCHAR), 3)
											) 

		end [current_step_duration]

	   
	from msdb.dbo.sysjobs_view jv
	
		left join msdb.dbo.syscategories  cat on
			jv.category_id = cat.category_id
	
		left join sys.server_principals sp on
			owner_sid = [sid]
	
		join msdb.dbo.sysjobactivity ja on
			jv.job_id = ja.job_id
			and run_requested_date is not NULL
			and stop_execution_date is NULL	
			and ja.session_id = (SELECT session_id FROM msdb.dbo.syssessions where agent_start_date = (select max(agent_start_date) from msdb.dbo.syssessions))


		left join msdb.dbo.sysjobsteps previous_step on
			ja.job_id = previous_step.job_id
			and ja.last_executed_step_id = previous_step.step_id


		left join msdb.dbo.sysjobsteps current_step on
			ja.job_id = current_step.job_id
			and coalesce(ja.last_executed_step_id + 1,isnull(last_executed_step_id,1)) = current_step.step_id

					 
		cross apply (select 
						sum((last_run_duration / 10000) * 3600 +           -- Hours to seconds
						((last_run_duration % 10000) / 100) * 60 +		 -- Minutes to seconds
						(last_run_duration % 100)
						) * 1000		[sum_last_step_run_ms]
					from msdb.dbo.sysjobsteps
					where	step_id <= previous_step.step_id
							and job_id = jv.job_id
						) sum_previous_steps_duration

		left join sys.dm_exec_sessions s on
			ja.[session_id] = s.[session_id]

	order by [total_job_duration] desc



end		/* end of detailed */




/*************************** SCRIPT FOR TEST JOB THAT RUNS 3 STEPS EACH 1 MINUTE DURATION ****************************

USE [msdb]
GO


BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0


IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'[Uncategorized (Local)]' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'[Uncategorized (Local)]'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'TestJob', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'No description available.', 
		@category_name=N'[Uncategorized (Local)]', 
		@owner_login_name=N'sa', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback



EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Test Job Step 1', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=3, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'
declare 
	@i int = 1,
	@report varchar(10)


while (@i <= 60) begin

	set @report = cast(@i as varchar)
	
	raiserror(@report, 0, 1) with nowait

	set @i = @i + 1

	waitfor delay ''00:00:01''

end', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback



EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Test Job Step 2', 
		@step_id=2, 
		@cmdexec_success_code=0, 
		@on_success_action=3, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'
declare 
	@i int = 1,
	@report varchar(10)


while (@i <= 60) begin

	set @report = cast(@i as varchar)
	
	raiserror(@report, 0, 1) with nowait

	set @i = @i + 1

	waitfor delay ''00:00:01''

end', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback


EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Test Job Step 3', 
		@step_id=3, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'
declare 
	@i int = 1,
	@report varchar(10)


while (@i <= 60) begin

	set @report = cast(@i as varchar)
	
	raiserror(@report, 0, 1) with nowait

	set @i = @i + 1

	waitfor delay ''00:00:01''

end', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:
GO

************************************************************************************************************/



end		/* end of procedure */



