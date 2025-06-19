

/********************* Error Reporting Solution for Azure SQL Managed Instance (and SQL Server) **********************

Version: 1.01

This script generates email alerts for errors of severity 17-25 on Azure SQL Managed Instance (and SQL Server).
Script reads from XEL file where to errors are logged, formats the text from xml values, and sends over email.

Extended Events session capturing "error_reported" events should be created as a prerequisite.


History:

2025-06-17 -> Aleksey Vitsko -> created the script


Tested / works on:
- Azure SQL Managed Instance (SQL 2022 update policy)
- SQL Server 2017 (CU31-GDR)



How to create and start the extended events session:

CREATE EVENT SESSION [Error_Reporting] ON SERVER 
ADD EVENT sqlserver.error_reported(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.session_server_principal_name,sqlserver.sql_text,sqlserver.username)
    WHERE ([severity]>=(17)))
ADD TARGET package0.event_file(SET filename=N'https://yourstorageaccount.blob.core.windows.net/extendedevents/Errors.xel',max_file_size=(102400),max_rollover_files=(5))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
GO

ALTER EVENT SESSION [Error_Reporting] ON SERVER STATE = START



How to reproduce an error:

raiserror('test error',17,1)
raiserror('test error severity 20, disconnects the session',20,1) with log


**********************************************************************************************************************/


SET QUOTED_IDENTIFIER ON

/* configurable parameters */
declare 
	@Path					nvarchar(260),					/* path to a XEL file (URL, but also can be local drive/fileshare for SQL Server) */
	@Minutes_Back			int,							/* lookback period in minutes (based on "timestamp_utc" in XEL file) */
	
	@_recipients			varchar(max),					/* list of email recipients */
	@_from_address			varchar(max),					/* from email address */
	@_reply_to				varchar(max),					/* reply to email address */
	@_subject				nvarchar(255)					/* subject of email */
	
	

/* specify your XEL file, look back period, and database mail settings */
set @Path					= 'https://yourstorageaccount.blob.core.windows.net/extendedevents/Errors_0_133945865715620000.xel'
set @Minutes_Back			= 5

set @_recipients			= 'dba@domain.com'
set @_from_address			= 'dba@domain.com'
set @_reply_to				= 'dba@domain.com'
set @_subject				= 'Error Reporting'



/* temp table for holding last N minutes of errors */
drop table if exists #Errors

create table #Errors (
	ID									int identity primary key,
	
	timestamp_utc						datetime,
	[database_name]						nvarchar(128) NULL,

	[error_number]						int,
	severity							int,
	[state]								int,
	category							int,
	category_desc						nvarchar(128),

	destination							nvarchar(128),
	session_server_principal_name		nvarchar(128) NULL,
	username							nvarchar(128) NULL,

	client_app_name						nvarchar(128) NULL,
	client_hostname						nvarchar(128) NULL,

	[message]							nvarchar(2048),
	sql_text							nvarchar(300) NULL				/* increase length if you want more of sql text */
	)

/* xml shredding */
insert into #Errors (timestamp_utc, [database_name], [error_number], severity, [state], category, destination, session_server_principal_name, username, client_app_name, client_hostname, [message], sql_text)
SELECT 
	[timestamp_utc] = cast(timestamp_utc as datetime),
	
	[database_name] = event_data_xml.value('(event/action[@name = "database_name"]/value/text())[1]', 'nvarchar(128)'),
	
	[error_number] = event_data_xml.value('(event/data[@name = "error_number"]/value/text())[1]', 'int'),
	severity = event_data_xml.value('(event/data[@name = "severity"]/value/text())[1]', 'int'),
	[state] = event_data_xml.value('(event/data[@name = "state"]/value/text())[1]', 'int'),
	category = event_data_xml.value('(event/data[@name = "category"]/value/text())[1]', 'sysname'),

	destination = event_data_xml.value('(event/data[@name = "destination"]/text/text())[1]', 'nvarchar(200)'),

	session_server_principal_name = event_data_xml.value('(event/action[@name = "session_server_principal_name"]/value/text())[1]', 'nvarchar(128)'),
	username = event_data_xml.value('(event/action[@name = "username"]/value/text())[1]', 'nvarchar(128)'),

	client_app_name = event_data_xml.value('(event/action[@name = "client_app_name"]/value/text())[1]', 'nvarchar(128)'),
	client_hostname = event_data_xml.value('(event/action[@name = "client_hostname"]/value/text())[1]', 'nvarchar(128)'),
	
	[message] = event_data_xml.value('(event/data[@name = "message"]/value/text())[1]', 'nvarchar(2048)'),

	[sql_text] = event_data_xml.value('(event/action[@name = "sql_text"]/value/text())[1]', 'nvarchar(300)')     /* increase length if you want more of sql text */

FROM sys.fn_xe_file_target_read_file(@Path, NULL, NULL, NULL) xft
CROSS APPLY (SELECT CAST(xft.event_data AS XML)) CA(event_data_xml)
where cast(timestamp_utc as datetime) > dateadd(minute,-@Minutes_Back, getdate())


/* resolve category description */
update #Errors 
	set category_desc = case category
		when 1 then 'UNKNOWN'
		when 2 then 'SERVER'
		when 3 then 'DATABASE'
		when 4 then 'LOGON'
		when 5 then 'JOB'
		when 6 then 'REPLICATION'
		when 7 then 'SECURITY'
		when 8 then 'USER'
		when 9 then 'QUERY PROCESSING'
		when 10 then 'SYSTEM'
		when 11 then 'RESOURCE'
		when 12 then 'IO'
		when 13 then 'NETWORKING'
		when 14 then 'BACKUP/RESTORE'
		when 15 then 'AGENT'
		when 16 then 'FULL-TEXT SEARCH'
		when 17 then 'CLR'
		when 18 then 'SERVICE BROKER'
		when 19 then 'DTC (Distributed Transactions)'
		when 20 then 'MEMORY'
		when 21 then 'SCHEDULER'
		when 22 then 'STORAGE'
		when 23 then 'EXECUTION'
		when 24 then 'DEADLOCK'
		when 25 then 'ALWAYS ON / HIGH AVAILABILITY'
		when 26 then 'POLYBASE'
		when 27 then 'MACHINE LEARNING SERVICES'
		when 28 then 'GRAPH PROCESSING'
		when 29 then 'TEMPORAL TABLES'
		when 30 then 'OTHER FEATURES'
end


/* fill the report's text */
declare 
	@ID				int = 1,
	@Report			nvarchar(max) = '',
	@NewLine		nvarchar(10) = CHAR(13) + CHAR(10)


while @ID <= (select max(ID) from #Errors) begin

select @Report = @Report + cast(@ID as nvarchar) +  '
Error number -- ' + cast([error_number] as nvarchar) + ',  Severity -- ' + cast(severity as nvarchar) + ',  State -- ' + cast([state] as nvarchar) + '
Timestamp UTC -- ' + convert(nvarchar,timestamp_utc,21) + '
Database name -- ' + isnull([database_name],'') + '
Category -- ' + category_desc + '
Destination -- ' + [destination] + '
Original login -- ' + isnull([session_server_principal_name],'') + '
Client hostname -- ' + isnull(client_hostname,'') + '
Message -- ' + [message] + '
SQL text -- ' + isnull(sql_text,'') + '

'
	from #Errors
	where ID = @ID

	set @ID = @ID + 1

end


/* send the report over email */
if (select count(*) from #Errors) > 0 begin

	exec msdb..sp_send_dbmail 
		@profile_name = 'AzureManagedInstance_dbmail_profile',    /* specify a different profile name, if you are on SQL Server */
		@recipients = @_recipients, 
		@from_address = @_from_address, 
		@reply_to = @_reply_to, 
		@subject = @_subject, 
		@body = @Report
end


     
