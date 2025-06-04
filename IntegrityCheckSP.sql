



-- use master

create or alter procedure IntegrityCheckSP (
	@TargetDB						varchar(250) = 'Database1, Database2',				-- database list 
	@ExcludeDBList					varchar(250) = NULL,								-- exclude specified databases 

	@NoIndex						bit = 0,											-- skip nonclustered index of user tables
	@NoInfoMsgs						bit = 0,											-- do not show info msgs
	@PhysicalOnly					bit = 0,											-- do not check for data purity
	@EstimateOnly					bit = 0,											-- estimate TempDB space usage 
	@TabLock						bit = 0,											-- attempt to acquire short-term exclusive lock on db instead of using db snapshot
	@ExtendedLogicalChecks			bit = 0,											-- logical checks are also performed on an indexed view, XML indexes, and spatial indexes, where present
	@MaxDOP							smallint = 0,										-- max degree of parallelism (SQL Server 2014 and later)

	@GenerateCommandsOnly			bit = 0,											-- only script commands, do not run actual dbcc check db

	@SendReportEmail				bit = 1,
	@EmailProfileName				varchar(100) = 'Server email alerts',				-- put your email profile name here
	@toList							varchar(500) = 'email@yourdomain.com'			-- put Operator here
)

as begin

set nocount on


/****************************************** INFO **********************************************************

Author: Aleksey Vitsko
Created: June 2018

Description: runs integrity check (dbcc check db command) against specified databases and sends email with results
Supports parameters (see Testing section below)


History:

2018-07-02
Fixed hour calculation algorithm

2018-06-10
Created procedure


**********************************************************************************************************/


/* TESTING

exec IntegrityCheckSP 
	@TargetDB = 'user', 
	@ExcludeDBList = 'LogsDB',
	@GenerateCommandsOnly = 0,
	@NoIndex = 0,
	@EstimateOnly = 0,
	@NoInfoMsgs = 0,
	@PhysicalOnly = 0,
	@TabLock = 0,
	@ExtendedLogicalChecks = 0


*/


/*
 -- debug arguments
declare 
	@TargetDB						varchar(250) = 'Database1, Database2',				-- database list 
	@ExcludeDBList					varchar(250) = NULL,								-- exclude specified databases

	@NoIndex						bit = 1,											-- skip nonclustered index of user tables
	@NoInfoMsgs						bit = 1,											-- do not show info msgs
	@PhysicalOnly					bit = 1,											-- do not check for data purity
	@EstimateOnly					bit = 1,											-- estimate TempDB space usage 
	@TabLock						bit = 1,											-- attempt to acquire short-term exclusive lock on db instead of using db snapshot
	@ExtendedLogicalChecks			bit = 0,											-- logical checks are also performed on an indexed view, XML indexes, and spatial indexes, where present
	@MaxDOP							smallint = 2,										-- max degree of parallelism (SQL Server 2014 and later)

	@GenerateCommandsOnly			bit = 1,											-- only script commands, do not run actual dbcc check db

	@SendReportEmail				bit = 1,
	@EmailProfileName				varchar(100) = 'Server email alerts',				-- put your email profile name here
	@toList							varchar(500) = 'email@yourdomain.com'			-- put Operator here

*/




----------------------------------------- Pre-Checks -------------------------------------------------

if @PhysicalOnly = 1 and @ExtendedLogicalChecks = 1 begin
	print '@PhysicalOnly (physical_only) and @ExtendedLogicalChecks (extended_logical_checks) can''t be used at the same time'
	return
end





----------------------------------------- Used Variables -------------------------------------------------

declare
	@DBname							varchar(150), 
	@DB_ID							int,
	@Error							int,

	-- execute statements
	@ActionStatement				varchar(500),

	-- measure time
	@Start							datetime,
	@End							datetime,
	@Diff							int,
	@ProgressText					varchar(500),

	@GlobalStart					datetime,
	@GlobalEnd						datetime,
	@GlobalTotalTime				varchar(10),

	-- db count
	@SuccessDBCount					int = 0,
	@FailureDBCount					int = 0,

	-- email report body message
	@SubjectText					varchar(200),
	@msg							varchar(max) = ''
	




---------------------------------- Tables for Logging --------------------------------

declare @DBCC_CheckDB_History table (
	tResult				varchar(15),
	tDBName				varchar(22),
	
	tStartTime			datetime,
	tEndTime			datetime,	
	
	tHours				int,
	tMinutes			int,
	tSeconds			int,
	
	tHoursVarchar		varchar(2),
	tMinutesVarchar		varchar(2),
	tSecondsVarchar		varchar(2),

	tErrorNumber		varchar(10),
	tErrorSeverity		varchar(5),
	tErrorMessage		varchar(500),
	
	tTotalTimeReport	varchar(10),
	
	primary key (tResult, tDBName))
	
	



----------------------------------------- Target DB ------------------------------------------------------

-- progress messages
set @GlobalStart = getdate()
set @Start = getdate()



-- database list
declare @databases table (
	DBName				varchar(150),
	dDB_ID				int)


-- all
if @TargetDB = 'all' begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] not in ('tempdb')
			and state_desc = 'ONLINE'
end

-- user
if @TargetDB in ('user','userdb') begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] not in ('tempdb','master','model','msdb')
			and state_desc = 'ONLINE'
end

-- system
if @TargetDB in ('system','systemdb') begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] in ('master','model','msdb')
			and state_desc = 'ONLINE'
end

-- even
if @TargetDB in ('even','evendb') begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] not in ('tempdb','master','model','msdb')
			and database_id % 2 = 0
			and state_desc = 'ONLINE'
end

-- odd
if @TargetDB in ('odd','odddb') begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] not in ('tempdb','master','model','msdb')
			and database_id % 2 = 1
			and state_desc = 'ONLINE'
end


-- specific db
if @TargetDB not in ('all','user','userdb','system','systemdb','even','evendb','odd','odddb') and exists (select * from sys.databases where [name] = @TargetDB) begin
	insert into @databases (dbName)
	select [name]
	from sys.databases
	where	[name] = @TargetDB
			and state_desc = 'ONLINE'
end



-- list of DBs
if @TargetDB like '%,%' or @TargetDB like '% %' or @TargetDB like '%;%' begin
	
	declare @Increment tinyint = 0, @StringLength tinyint, @char varchar(1), @DBNameToInsert varchar(50)

	set @Increment = 1	
	set @StringLength = len(@TargetDB)
	set @DBNameToInsert = ''

	while @Increment <= @StringLength begin

		set @char = substring(@TargetDB,@Increment,1)

		if @char not in (' ',',',';') begin
			set @DBNameToInsert = @DBNameToInsert + @char
		end

		if @char in (' ',',',';') begin
			if exists (select * from sys.databases where [name] = @DBNameToInsert and state_desc = 'ONLINE') and not exists (select * from @databases where DBName = @DBNameToInsert) begin 
				insert into @databases (DBName)
				select @DBNameToInsert
			end	

			set @DBNameToInsert = ''
		end

		if @Increment = @StringLength begin
			if exists (select * from sys.databases where [name] = @DBNameToInsert and state_desc = 'ONLINE') and not exists (select * from @databases where DBName = @DBNameToInsert) begin 
				insert into @databases (DBName)
				select @DBNameToInsert
			end	
		end

		set @Increment = @Increment + 1
	
	end

end


-- DBs to exclude
if @ExcludeDBList is not NULL begin

	declare @DatabasesExclude table (
		DBNameExclude			varchar(150))
	
	declare @Increment2 tinyint = 0, @StringLengthEx tinyint, @char2 varchar(1), @DBNameToExclude varchar(50)

	set @Increment2 = 1	
	set @StringLengthEx = len(@ExcludeDBList)
	set @DBNameToExclude = ''

	while @Increment2 <= @StringLengthEx begin

		set @char2 = substring(@ExcludeDBList,@Increment2,1)

		if @char2 not in (' ',',',';') begin
			set @DBNameToExclude = @DBNameToExclude + @char2
		end

		if @char2 in (' ',',',';') begin
			if exists (select * from sys.databases where [name] = @DBNameToExclude and state_desc = 'ONLINE') and not exists (select * from @DatabasesExclude where DBNameExclude = @DBNameToExclude) begin 
				insert into @DatabasesExclude (DBNameExclude)
				select @DBNameToExclude
			end	

			set @DBNameToExclude = ''
		end

		if @Increment2 = @StringLengthEx begin
			if exists (select * from sys.databases where [name] = @DBNameToExclude and state_desc = 'ONLINE') and not exists (select * from @DatabasesExclude where DBNameExclude = @DBNameToExclude) begin 
				insert into @DatabasesExclude (DBNameExclude)
				select @DBNameToExclude
			end	
		end

		set @Increment2 = @Increment2 + 1
	
	end

	delete d
	from @databases d
		join @DatabasesExclude on
			dbName = DBNameExclude

end


-- get database id
update @Databases
	set dDB_ID = database_id
from @Databases
	join sys.databases on
		DBName = [name]






-- progress messages
set @End = getdate()
set @Diff = datediff(second,@Start,@End)

set @ProgressText = case 
		when @ExcludeDBList is NULL then 'Obtained Target DB List - ' + @TargetDB + ' - ' + cast(@Diff as varchar) + ' sec
		'
		when @ExcludeDBList is not NULL then 'Obtained Target DB List - ' + @TargetDB + 'excluding ' + @ExcludeDBList + ' - ' + cast(@Diff as varchar) + ' sec
		'
	end
RAISERROR ( @ProgressText, 0, 1 ) WITH NOWAIT; 





---------------------------------------- DB Cursor Logic --------------------------------------------

declare @counter int = 1


declare DB_List cursor local fast_forward for
select dbName, dDB_ID
from @databases
order by dbName

open DB_List
fetch next from DB_List into @DBname, @DB_ID


while @@FETCH_STATUS = 0 begin

	-- build command
	set @ActionStatement = 'DBCC CheckDB ( ' + @DBName 
	
		-- no index command
		if @NoIndex = 1 begin 
			set @ActionStatement = @ActionStatement + ' , NoIndex' 
		end

		set @ActionStatement = @ActionStatement + ' )'

		-- with options
		if @NoInfoMsgs = 1 or @PhysicalOnly = 1 or @EstimateOnly = 1 or @TabLock = 1 or @ExtendedLogicalChecks = 1 or @MaxDOP > 0 begin
			set @ActionStatement = @ActionStatement + ' with' 
		end
		
		-- no info msgs
		if @NoInfoMsgs = 1 begin 
			set @ActionStatement = @ActionStatement + ' no_infomsgs' 
		end

		-- physical only
		if @PhysicalOnly = 1 begin 
			if right(@ActionStatement,5) <> ' with' begin set @ActionStatement = @ActionStatement + ',' end
			set @ActionStatement = @ActionStatement + ' physical_only' 
		end

		-- estimate only
		if @EstimateOnly = 1 begin 
			if right(@ActionStatement,5) <> ' with' begin set @ActionStatement = @ActionStatement + ',' end
			set @ActionStatement = @ActionStatement + ' estimateonly' 
		end

		-- tablock
		if @TabLock = 1 begin 
			if right(@ActionStatement,5) <> ' with' begin set @ActionStatement = @ActionStatement + ',' end
			set @ActionStatement = @ActionStatement + ' tablock' 
		end

		-- extended logical checks
		if @ExtendedLogicalChecks = 1 begin 
			if right(@ActionStatement,5) <> ' with' begin set @ActionStatement = @ActionStatement + ',' end
			set @ActionStatement = @ActionStatement + ' extended_logical_checks' 
		end

		-- max dop
		if @MaxDOP > 0 begin 
			if right(@ActionStatement,5) <> ' with' begin set @ActionStatement = @ActionStatement + ',' end
			set @ActionStatement = @ActionStatement + ' MaxDOP = ' + cast(@MaxDOP as varchar) 
		end


		-- print command only
		if @GenerateCommandsOnly = 1 begin
			print @ActionStatement
		end
				

		-- execute command
		if @GenerateCommandsOnly = 0 begin
								
				-- measure time
				set @Start = getdate()

				print 'Starting ' + @DBName + '...'
				print @ActionStatement

				-- run command
				exec (@ActionStatement) 
				set @Error = @@ERROR


				-- if no errors during dbcc checkdb
				if @Error = 0 begin
					
					set @End = getdate()
					print @DBName + ' -- status: OK'

					-- measure time, logging success operation
					insert into @DBCC_CheckDB_History (tResult, tDBName, tStartTime, tEndTime, tHours, tMinutes, tSeconds)
					select 
						'Success',
						@DBName,

						@Start,
						@End,

						case 
							when datediff(minute,@start,@end) < 60 and datediff(hour,@start,@end) > 0 then 0
							else datediff(hour,@start,@end)
						end,
						case 
							when datediff(second,@start,@end) < 60 and (datediff(minute,@start,@end) - ((datediff(minute,@start,@end)) / 60) * 60) > 0 then 0
							else datediff(minute,@start,@end) - ((datediff(minute,@start,@end)) / 60) * 60
						end,
						datediff(second,@start,@end) - ((datediff(second,@start,@end)) / 60) * 60
				
				end		-- end of no errors section



				-- if there were errors during dbcc check db
				if @Error <> 0 begin
					
					set @End = getdate()
					print @DBName + ' -- status: ERROR'

					-- measure time, logging success operation
					insert into @DBCC_CheckDB_History (tResult, tDBName, tStartTime, tEndTime, tHours, tMinutes, tSeconds, tErrorNumber)
					select 
						'Error',
						@DBName,

						@Start,
						@End,

						case 
							when datediff(minute,@start,@end) < 60 and datediff(hour,@start,@end) > 0 then 0
							else datediff(hour,@start,@end)
						end,
						case 
							when datediff(second,@start,@end) < 60 and (datediff(minute,@start,@end) - ((datediff(minute,@start,@end)) / 60) * 60) > 0 then 0
							else datediff(minute,@start,@end) - ((datediff(minute,@start,@end)) / 60) * 60
						end,
						datediff(second,@start,@end) - ((datediff(second,@start,@end)) / 60) * 60,

						@Error
				end		-- end of error encountered section

				print ''
			

		end		-- end of execute command section


	-- get next database from the list
	fetch next from DB_List into @DBname, @DB_ID

end			-- end of db cursor logic



close DB_List
deallocate DB_List



-- get error severity and message
update @DBCC_CheckDB_History
	set tErrorSeverity = severity,
		tErrorMessage = [text]
from @DBCC_CheckDB_History
	join sys.messages on
		tErrorNumber = message_id
		and language_id = 1033
where	tErrorNumber is not NULL






---------------------------------------- Email Report --------------------------------------------

-- prepare time measurements for the report
set @GlobalEnd = GETDATE()


declare @TotalTime table (
	ttHours				int,
	ttMinutes			int,
	ttSeconds			int,
	ttHoursVarchar		varchar(5),
	ttMinutesVarchar	varchar(5),
	ttSecondsVarchar	varchar(5),
	ttTotalTimeReport	varchar(10))

insert into @TotalTime (ttHours, ttMinutes, ttSeconds)
select 
	case 
		when datediff(minute,@GlobalStart,@GlobalEnd) < 60 and datediff(hour,@GlobalStart,@GlobalEnd) > 0 then 0
		else datediff(hour,@GlobalStart,@GlobalEnd)
	end,
	case 
		when datediff(second,@GlobalStart,@GlobalEnd) < 60 and (datediff(minute,@GlobalStart,@GlobalEnd) - ((datediff(minute,@GlobalStart,@GlobalEnd)) / 60) * 60) > 0 then 0
		else datediff(minute,@GlobalStart,@GlobalEnd) - ((datediff(minute,@GlobalStart,@GlobalEnd)) / 60) * 60
	end,
	datediff(second,@GlobalStart,@GlobalEnd) - ((datediff(second,@GlobalStart,@GlobalEnd)) / 60) * 60


update @TotalTime
	set ttHoursVarchar = right('00' + cast(ttHours as varchar),2),
		ttMinutesVarchar = right('00' + cast(ttMinutes as varchar),2),
		ttSecondsVarchar = right('00' + cast(ttSeconds as varchar),2)


update @TotalTime
	set ttTotalTimeReport = ttHoursVarchar + ':' + ttMinutesVarchar + ':' + ttSecondsVarchar


-- global total time in nice format
set @GlobalTotalTime = (select ttTotalTimeReport from @TotalTime)




-- total time for each individual db
update @DBCC_CheckDB_History
	set tHoursVarchar = right('00' + cast(tHours as varchar),2),
		tMinutesVarchar = right('00' + cast(tMinutes as varchar),2),
		tSecondsVarchar = right('00' + cast(tSeconds as varchar),2)

update @DBCC_CheckDB_History
	set tTotalTimeReport = tHoursVarchar + ':' + tMinutesVarchar + ':' + tSecondsVarchar

	
-- count of successful / error checkdb
set @SuccessDBCount = (select count(*) from @DBCC_CheckDB_History where tResult = 'Success')
set @FailureDBCount = (select count(*) from @DBCC_CheckDB_History  where tResult = 'Error')



-- email subject text
set @SubjectText = case 
	when @FailureDBCount = 0 then 'DB Integrity / Consistency Checks -- SUCCESS'
	when @FailureDBCount > 0 then 'DB Integrity / Consistency Checks -- with FAILURE(s)'
end



-- email body message
declare @SummaryLine varchar(500)

set @SummaryLine = case
	when @FailureDBCount = 0 then 'CheckDB succeeded: ' + cast (@SuccessDBCount as varchar) 
	when @FailureDBCount > 0 then 'CheckDB succeeded: ' + cast (@SuccessDBCount as varchar) + ' / ' + cast(@FailureDBCount as varchar) + ' FAILED (!)'
end


-- email body message summary lines
set @msg = @msg + '
	Total Job Run Time --- ' + @GlobalTotalTime + '
	' + @SummaryLine + '
'




declare @tResult varchar(15), @tDBName varchar(150), @tStartTime datetime, @tEndTime datetime, @tTotalTimeReport varchar(10), @tErrorNumber int, @tErrorSeverity tinyint, @tErrorMessage varchar(500)

if @FailureDBCount > 0 begin

	set @msg = @msg + '
	ERROR CheckDB:

'
	
	declare FailedCheckDB cursor local fast_forward for
	select tDBName, tStartTime, tEndTime, tTotalTimeReport, tErrorNumber, tErrorSeverity, tErrorMessage
	from @DBCC_CheckDB_History
	where tResult = 'Error'
	order by tDBName

	open FailedCheckDB
	fetch next from FailedCheckDB into @tDBName, @tStartTime, @tEndTime, @tTotalTimeReport, @tErrorNumber, @tErrorSeverity, @tErrorMessage

	while @@FETCH_STATUS = 0 begin

	set @msg = @msg + @tDBName + ' -- ' + 'Start: ' + cast(@tStartTime as varchar) + ' -- End: ' + cast(@tEndTime as varchar) + ' -- Duration:  ' + @tTotalTimeReport + '
(Last Error Number: ' + cast(@tErrorNumber as varchar) +  ' -- Error Severity: ' + cast(@tErrorSeverity as varchar) + ' -- Error Message: ' + @tErrorMessage + ')

'

		fetch next from FailedCheckDB into @tDBName, @tStartTime, @tEndTime, @tTotalTimeReport, @tErrorNumber, @tErrorSeverity, @tErrorMessage
	end

	close FailedCheckDB
	deallocate FailedCheckDB

end


-- success check db details
if (select count(*) from @DBCC_CheckDB_History where tResult = 'Success' ) > 0 begin

	set @msg = @msg + '
	SUCCESSFUL CheckDB:

'
	
	declare SuccessfulCheckDB cursor local fast_forward for
	select tDBName, tStartTime, tEndTime, tTotalTimeReport
	from @DBCC_CheckDB_History
	where tResult = 'Success'
	order by tDBName

	open SuccessfulCheckDB
	fetch next from SuccessfulCheckDB into @tDBName, @tStartTime, @tEndTime, @tTotalTimeReport

	while @@FETCH_STATUS = 0 begin

	set @msg = @msg + @tDBName + ' -- ' + 'Start: ' + cast(@tStartTime as varchar) + ' -- End: ' + cast(@tEndTime as varchar) + ' -- Duration:  ' + @tTotalTimeReport + '

'
		
		fetch next from SuccessfulCheckDB into @tDBName, @tStartTime, @tEndTime, @tTotalTimeReport
	end

	close SuccessfulCheckDB
	deallocate SuccessfulCheckDB

end












-- show results
if @GenerateCommandsOnly = 0 begin
	
	select * from @DBCC_CheckDB_History
	
	-- progress message
	set @ProgressText = '
	---------- Email Report -----------
		'
	RAISERROR (@ProgressText, 0, 1) with NOWAIT

	print @msg
		
	-- email
	if @SendReportEmail = 1 begin
		
		begin try
			set @SubjectText = 'DBCC CheckDB - Integrity Check Report'

			EXEC msdb.dbo.sp_send_dbmail 
				@profile_name = @EmailProfileName, 
				@recipients = @toList, 
				@subject = @SubjectText, 
				@body = @msg
		end try
		
		begin catch
			print 'Sending email failed'
		end catch

	end			-- end of email send procedure

end			-- end of show results section



end			-- end of procedure's logic

