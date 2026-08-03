

/* exec ViewServerProperties */

/* use master */

create or alter procedure ViewServerProperties (
	@command			varchar(20) = 'all'
	)  
as begin 

/************************************************************** VIEW SERVER PROPERTIES PROCEDURE *************************************************************

Author: Aleksey Vitsko

Version: 1.16


Description: 

Shows host OS, server machine (cpu, memory, etc.), and SQL Server instance-level properties and configuration options.


History:

2026-08-03 -> Aleksey Vitsko - additional memory info for Azure SQL DB; other adjustments
2026-08-03 -> Aleksey Vitsko - new sections SQL instance memory and cpu, add maxdop and cpu rate (azure sql, job object)
2026-08-03 -> Aleksey Vitsko - use /* */ for comments only
2026-08-03 -> Aleksey Vitsko - split cpu and memory (machine) into two sections
2026-08-01 -> Aleksey Vitsko - additional machine memory info from "sys.dm_os_sys_memory"
2026-08-01 -> Aleksey Vitsko - rearrange sort order for the output information 
2026-07-31 -> Aleksey Vitsko - added new "Engine Edition" description (12) and "container_type_desc"
2026-07-31 -> Aleksey Vitsko - added support for "host_architecture" column from "sys.dm_os_host_info"
2026-07-31 -> Aleksey Vitsko - added support for "sys.dm_os_host_info" and server config options for Azure SQL MI

2022-09-12 -> Aleksey Vitsko - query "sys.dm_os_host_info" only if SQL Server product major version >= 14
2022-09-12 -> Aleksey Vitsko - bring "engine edition description" up to date with current Microsoft docs
2022-09-12 -> Aleksey Vitsko - "sys.dm_os_sys_info" is now supported on Azure SQL DB, Azure SQL MI etc.
2022-09-12 -> Aleksey Vitsko - added scheduler count, total scheduler count, max worker count to the output
2022-09-09 -> Aleksey Vitsko - rearranged CPU, SQL memory and SQL instance-related columns, added NUMA node count column
2022-09-09 -> Aleksey Vitsko - added host OS information to the output

2019-05-31 -> Aleksey Vitsko - added more CPU and Memory information in the output (number of sockets, used memory, virtual memory etc.)
2018-07-24 -> Aleksey Vitsko - added server config options (sp_configure) to the output
2018-07-21 -> Aleksey Vitsko - added machine specs to the output
2018-07-19 -> Aleksey Vitsko - created procedure


Tested on:

- SQL Server 2016 (SP2), 2017 (RTM), 2019 (RTM), 2022 (RTM), 2025 (RTM)
- Azure SQL Managed Instance (SQL 2022 update policy)
- Azure SQL Database


*****************************************************************************************************************************************************************

Supported commands (@command parameter):

'all'			- line, table, print commands are used
'line'			- output is a single row with many columns
'multiselect'	- output is several result sets
'table'			- output is in table format
'print'			- output is printed 

*****************************************************************************************************************************************************************/


set nocount on


/********************************************************** Variables ********************************************************/

declare 
	
	/* server */
	@ServerName								varchar(128) = cast(serverproperty('ServerName') as varchar(128)),
	@MachineName							varchar(128) = cast(isnull(serverproperty('MachineName'),'n/a')	 as varchar(128)),
	@ComputerNamePhysicalNetBios			varchar(128) = cast(isnull(serverproperty('ComputerNamePhysicalNetBios'),'n/a') as varchar(128)),
	@VirtualMachineType						varchar(128) = 'n/a',
	@ContainerTypeDesc						varchar(128) = 'n/a',

	/* OS host info */
	@HostPlatform							varchar(128) = 'n/a',
	@HostDistribution						varchar(128) = 'n/a',
	@HostRelease							varchar(128) = 'n/a',
	@HostServicePackLevel					varchar(128) = 'n/a',
	@HostSKU								varchar(128) = 'n/a',
	@OSLanguageVersion						varchar(128) = 'n/a',
	@HostArchitecture						varchar(128) = 'n/a',

	/* cpu (machine) */
	@SocketCount							varchar(128) = 'n/a',
	@CoresPerSocket							varchar(128) = 'n/a',
	@HyperThreadRatio						varchar(128) = 'n/a',
	@LogicalCPUCount						varchar(128) = 'n/a',
	@NumaNodeCount							varchar(128) = 'n/a',
				

	/* memory (machine) */
	@VirtualMemoryGB						varchar(128) = 'n/a',
	@PhysicalMemoryGB						varchar(128) = 'n/a',
	@AvailablePhysicalMemoryGB				varchar(128) = 'n/a',
	@PageFileGB								varchar(128) = 'n/a',
	@AvailablePageFileGB					varchar(128) = 'n/a',	
	@SystemCacheGB							varchar(128) = 'n/a',	
	@KernelPagedPoolGB						varchar(128) = 'n/a',
	@KernelNonPagedPoolGB					varchar(128) = 'n/a',	
	@SystemMemoryState						varchar(128) = 'n/a',


	/* SQL instance cpu */
	@MaxDOP									varchar(128) = 'n/a',
	@CPURateAzureSQL						varchar(128) = 'n/a',
	@SchedulerCount							varchar(128) = 'n/a',
	@SchedulerTotalCount					varchar(128) = 'n/a',
	@MaxWorkersCount						varchar(128) = 'n/a',

	/* SQL instance memory */

	@CommittedMemoryGB						varchar(128) = 'n/a',
	@CommittedTargetMemoryGB				varchar(128) = 'n/a',
	@MemoryUsedPercentage					varchar(128) = 'n/a',
	@SQLMemoryModelDesc						varchar(128) = 'n/a',
	@ProcessMemoryLimitGB					varchar(128) = 'n/a',


	/* instance */
	@InstanceName							varchar(128) = cast(isnull(serverproperty('InstanceName'),'(default)') as varchar(128)),
	@ServiceName							varchar(128) = 'n/a', /* = @@SERVICENAME */
	@SQLServerStartTime						varchar(128) = 'n/a',
	@ProcessID								varchar(128) = cast(isnull(serverproperty('ProcessID'),'n/a') as varchar(128)),
	@Language								varchar(128) = cast(@@LANGUAGE as varchar(128)),
	@InstanceDefaultDataPath				varchar(128) = cast(isnull(serverproperty('InstanceDefaultDataPath'),'n/a') as varchar(128)),
	@InstanceDefaultLogPath					varchar(128) = cast(isnull(serverproperty('InstanceDefaultLogPath'),'n/a') as varchar(128)),
	@IsIntegratedSecurityOnly				varchar(128) = cast(serverproperty('IsIntegratedSecurityOnly') as varchar(128)),
	@IsSingleUser							varchar(128) = cast(serverproperty('IsSingleUser') as varchar(128)),
	@MaxConnections							varchar(128) = cast(@@MAX_CONNECTIONS as varchar(128)),
	@MaxPrecision							varchar(128) = cast(@@MAX_PRECISION as varchar(128)),
	
		
	/* edition */
	@Edition								varchar(128) = cast(serverproperty('Edition') as varchar(128)),
	@EditionID								varchar(128) = cast(serverproperty('EditionID')	 as varchar(128)),
	@EngineEdition							varchar(128) = cast(serverproperty('EngineEdition') as varchar(128)),
	@EngineEditionDesc						varchar(128),
	
	/* version */
	@BuildCLRVersion						varchar(128) = cast(isnull(serverproperty('BuildCLRVersion'),'n/a') as varchar(128)),
	@ProductBuild							varchar(128) = cast(serverproperty('ProductBuild') as varchar(128)),
	@ProductBuildType						varchar(128) = cast(isnull(serverproperty('ProductBuildType'),'n/a') as varchar(128)),
	@ProductLevel							varchar(128) = cast(serverproperty('ProductLevel') as varchar(128)),
	@ProductUpdateLevel						varchar(128) = cast(isnull(serverproperty('ProductUpdateLevel'),'n/a') as varchar(128)),
	@ProductVersion							varchar(128) = cast(serverproperty('ProductVersion') as varchar(128)),
	@ProductMajorVersion					varchar(128) = cast(serverproperty('ProductMajorVersion') as varchar(128)),
	@ProductMinorVersion					varchar(128) = cast(serverproperty('ProductMinorVersion') as varchar(128)),
	@ProductUpdateReference					varchar(128) = cast(isnull(serverproperty('ProductUpdateReference'),'n/a') as varchar(128)),
	@VersionFullDesc						varchar(128) = cast(@@VERSION as varchar(128)),

	/* features */	
	@IsLocalDB								varchar(128) = cast(isnull(serverproperty('IsLocalDB'),'n/a') as varchar(128)),
	@IsFullTextInstalled					varchar(128) = cast(serverproperty('IsFullTextInstalled') as varchar(128)),
	@IsAdvancedAnalyticsInstalled			varchar(128) = cast(isnull(serverproperty('IsAdvancedAnalyticsInstalled'),'n/a') as varchar(128)),
	@IsPolybaseInstalled					varchar(128) = cast(isnull(serverproperty('IsPolybaseInstalled'),'n/a') as varchar(128)),
	@IsXTPSupported							varchar(128) = cast(isnull(serverproperty('IsXTPSupported'),'n/a') as varchar(128)),

	/* cluster and hadr */
	@IsClustered							varchar(128) = cast(isnull(serverproperty('IsClustered'),'n/a') as varchar(128)),
	@IsHadrEnabled							varchar(128) = cast(isnull(serverproperty('IsHadrEnabled'),'n/a') as varchar(128)),
	@HadrManagerStatus						varchar(128) = cast(isnull(serverproperty('HadrManagerStatus'),'n/a') as varchar(128)),
	
	/* collation */
	@Collation								varchar(128) = cast(serverproperty('Collation') as varchar(128)),
	@CollationID							varchar(128) = cast(serverproperty('CollationID') as varchar(128)),
	@ComparisonStyle						varchar(128) = cast(serverproperty('ComparisonStyle') as varchar(128)),
	@LCID									varchar(128) = cast(serverproperty('LCID') as varchar(128)),
	@SqlCharSet								varchar(128) = cast(serverproperty('SqlCharSet') as varchar(128)),
	@SqlCharSetName							varchar(128) = cast(serverproperty('SqlCharSetName') as varchar(128)),
	@SqlSortOrder							varchar(128) = cast(serverproperty('SqlSortOrder') as varchar(128)),
	@SqlSortOrderName						varchar(128) = cast(serverproperty('SqlSortOrderName') as varchar(128)),
	
	/* filestream */
	@FilestreamShareName					varchar(128) = cast(isnull(serverproperty('FilestreamShareName'),'n/a') as varchar(128)),
	@FilestreamConfiguredLevel				varchar(128) = cast(serverproperty('FilestreamConfiguredLevel')	 as varchar(128)),
	@FilestreamEffectiveLevel				varchar(128) = cast(serverproperty('FilestreamEffectiveLevel') as varchar(128)),
	
	/* resource database */
	@ResourceVersion						varchar(128) = cast(serverproperty('ResourceVersion') as varchar(128)),
	@ResourceLastUpdateDateTime				varchar(128) = cast(serverproperty('ResourceLastUpdateDateTime') as varchar(128)),

	/* server config options */
	@ServerConfigOptionsLine				varchar(max) = ''

	

/* engine edition description */
set @EngineEditionDesc = case @EngineEdition
	when '1' then 'Personal or Desktop (before SQL Server 2005)'
	when '2' then 'Standard (Standard or Web or BI)'
	when '3' then 'Enterprise (Enterprise or Evaluation or Developer)'
	when '4' then 'Express (Express or Express with Tools or Express with Adv.Services)'
	when '5' then 'SQL Database'
	when '6' then 'Microsoft Azure Synapse Analytics'
	when '8' then 'Azure SQL Managed Instance'
	when '9' then 'Azure SQL Edge'
	when '11' then 'Azure Synapse serverless SQL pool'
	when '12' then 'Microsoft Fabric SQL Database in Microsoft Fabric'
end



/* SQL Server host OS info, service name, server config options */
if (@EngineEdition not in ('5','6','9','11') and cast(@ProductMajorVersion as int) >= 14) or @EngineEdition = '8'  begin

	/* host os */
	select
		@HostPlatform					= cast(host_platform as varchar(128)),
		@HostRelease					= cast(host_release as varchar(128)),
		@HostDistribution				= cast(host_distribution as varchar(128)),
		@HostServicePackLevel			= cast(host_service_pack_level as varchar(128)), 
		@HostSKU						= cast(host_sku as varchar(128)), 
		@OSLanguageVersion				= cast(os_language_version as varchar(128)) 
	from sys.dm_os_host_info

		
	/* host architecture available in SQL Server 2019+ and Azure SQL MI */
	if cast(@ProductMajorVersion as int) >= 15 or @EngineEdition = '8' begin

		select @HostArchitecture = cast(host_architecture as varchar(128)) 
		from sys.dm_os_host_info
	end


	/* service name */
	declare @exec varchar(max)

	set @exec = 'create table ##ServiceName_global (tServiceName varchar(128)) 
	insert into ##ServiceName_global (tServiceName) 
	select @@SERVICENAME'

	exec(@exec)
	set @ServiceName = (select top 1 isnull(tServiceName,'n/a') from ##ServiceName_global)
	drop table ##ServiceName_global


	/* server config options */
	declare @i int = 1

	declare @ServerConfigOptions table (
		ID						int primary key identity,
		ConfigOptionName		varchar(100),
		MinimumValue			int,
		MaximumValue			bigint,
		ConfigValue				bigint,
		CurrentValue			bigint)


	insert into @ServerConfigOptions (ConfigOptionName, MinimumValue, MaximumValue, ConfigValue, CurrentValue)
	exec sp_configure 

	
	while @i <= (select max(ID) from @ServerConfigOptions) begin
		set @ServerConfigOptionsLine = @ServerConfigOptionsLine + (select ConfigOptionName from @ServerConfigOptions where ID = @i) + ' = ' + (select cast(CurrentValue as varchar) from  @ServerConfigOptions where ID = @i) + '; '
		set @i += 1
	end

end



/* machine and sql server instance info */
select
	@NumaNodeCount					= cast(numa_node_count as varchar(128)),
	@SocketCount					= cast(socket_count as varchar(128)),
	@CoresPerSocket					= cast(cores_per_socket as varchar(128)),
	@HyperThreadRatio				= cast(hyperthread_ratio as varchar(128)),
	@LogicalCPUCount				= cast(cpu_count as varchar(128)),
		
	@PhysicalMemoryGB				= cast((physical_memory_kb / 1048576) as varchar(128)),
	@VirtualMemoryGB				= cast((virtual_memory_kb / 1048576) as varchar(128)), 	

	@CommittedMemoryGB				= substring(cast((cast(committed_kb as decimal(20,2)) / 1024 / 1024) as varchar(128)),1,charindex('.',cast((cast(committed_kb as decimal(20,2)) / 1024 / 1024) as varchar(128))) + 2),
	@CommittedTargetMemoryGB		= substring(cast((cast(committed_target_kb as decimal(20,2)) / 1024 / 1024) as varchar(128)),1,charindex('.',cast((cast(committed_target_kb as decimal(20,2)) / 1024 / 1024) as varchar(128))) + 2),
		
	@SQLMemoryModelDesc				= cast(sql_memory_model_desc as varchar(128)), 	
	@MemoryUsedPercentage			= substring(cast((cast(committed_kb as decimal(20,2)) / cast(committed_target_kb  as decimal(20,2)) * 100) as varchar),1,5) + ' %',
		
	@SQLServerStartTime				= cast(sqlserver_start_time as varchar(128)),
	@VirtualMachineType				= cast(virtual_machine_type_desc as varchar(128)),

	@SchedulerCount					= cast(scheduler_count as varchar(128)),
	@SchedulerTotalCount			= cast(scheduler_total_count as varchar(128)),
	@MaxWorkersCount				= cast(max_workers_count as varchar(128))

from sys.dm_os_sys_info



if cast(@ProductMajorVersion as int) >= 15 or @EngineEdition in ('5','8') begin

	select @ContainerTypeDesc = container_type_desc
	from sys.dm_os_sys_info

end



/* machine memory info */
if @EngineEdition not in ('5') begin
	select 
		@AvailablePhysicalMemoryGB = cast(cast(available_physical_memory_kb as decimal(32,2)) / 1024 / 1024	 as decimal(32,2)),
		@PageFileGB = cast(cast(total_page_file_kb as decimal(32,2)) / 1024 / 1024 as decimal(32,2)),
		@AvailablePageFileGB = cast(cast(available_page_file_kb as decimal(32,2)) / 1024 / 1024 as decimal(32,2)),
		@SystemCacheGB = cast(cast(system_cache_kb as decimal(32,2)) / 1024 / 1024 as decimal(32,2)),
		@KernelPagedPoolGB = cast(cast(kernel_paged_pool_kb as decimal(32,2)) / 1024 / 1024 as decimal(32,2)),
		@KernelNonPagedPoolGB = cast(cast(kernel_nonpaged_pool_kb as decimal(32,2)) / 1024 / 1024 as decimal(32,2)),
		@SystemMemoryState = system_memory_state_desc
	from sys.dm_os_sys_memory

end


/* memory limit for Azure SQL DB or elastic pool */
if @EngineEdition = '5' begin

	set @ProcessMemoryLimitGB = (select cast(cast((cast(process_memory_limit_mb as decimal(32,2)) / 1024) as decimal(32,2)) as varchar(128)) from sys.dm_os_job_object)

end



/* hadr manager status description */
if @HadrManagerStatus = '0' begin set @HadrManagerStatus = '0 - Not started, pending communication' end
if @HadrManagerStatus = '1' begin set @HadrManagerStatus = '1 - Started and running' end
if @HadrManagerStatus = '2' begin set @HadrManagerStatus = '2 - Not started and failed' end




/* cpu related */
if @EngineEdition in ('5','8') begin

	set @CPURateAzureSQL = (select cast(cpu_rate as varchar(128)) from sys.dm_os_job_object)

end


set @MaxDOP = (select cast(value_in_use as varchar(128)) from sys.configurations where [name] = 'max degree of parallelism')

if @MaxDOP is NULL begin
	set @MaxDOP = '"show advanced options" is turned off'
end


if @MaxDOP = '0' begin
	set @MaxDOP = @MaxDOP + ' (use all available CPUs for a query)'
end



/************************************************** Show Results ***********************************************/

/********* Line ********/

if @command in ('all','line') begin

select 
	/* server */
	@ServerName								[ServerName],
	@MachineName							[MachineName],
	@ComputerNamePhysicalNetBios			[ComputerNamePhysicalNetBios],
	@VirtualMachineType						[VirtualMachineType],
	@ContainerTypeDesc						[ContainerTypeDesc],

	/* host os info */
	@HostPlatform							[HostPlatform],
	@HostRelease							[HostRelease],
	@HostDistribution						[HostDistribution],
	@HostArchitecture						[HostArchitecture],

	/* cpu (machine) */
	@SocketCount							[SocketCount],
	@CoresPerSocket							[CoresPerSocket],
	@HyperThreadRatio						[HyperThreadRatio],
	@LogicalCPUCount						[LogicalCPUCount],
	@NumaNodeCount							[NumaNodeCount],
	
	/* memory (machine) */
	@VirtualMemoryGB						[VirtualMemoryGB],
	@PhysicalMemoryGB						[PhysicalMemoryGB],
	@AvailablePhysicalMemoryGB				[AvailablePhysicalMemoryGB],
	@PageFileGB								[PageFileGB],
	@AvailablePageFileGB					[AvailablePageFileGB],
	@SystemCacheGB							[SystemCacheGB],
	@KernelPagedPoolGB						[KernelPagedPoolGB],
	@KernelNonPagedPoolGB					[KernelNonPagedPoolGB],
	@SystemMemoryState						[SystemMemoryState],


	/* sql server instance */
	@InstanceName							[InstanceName],
	@ServiceName							[ServiceName],
	@SQLServerStartTime						[SQLServerStartTime],
	@ProcessID								[ProcessID],
	
	@Language								[Language],
	@InstanceDefaultDataPath				[InstanceDefaultDataPath],
	@InstanceDefaultLogPath					[InstanceDefaultLogPath],
	@IsIntegratedSecurityOnly				[IsIntegratedSecurityOnly],
	@IsSingleUser							[IsSingleUser],
	@MaxConnections							[MaxConnections],
	@MaxPrecision							[MaxPrecision],
	
	

	/* cpu (SQL instance) */
	@MaxDOP									[MaxDOP],
	@CPURateAzureSQL						[CPURateAzureSQL],
	@SchedulerCount							[SchedulerCount],
	@SchedulerTotalCount					[SchedulerTotalCount],
	@MaxWorkersCount						[MaxWorkersCount],


	/* memory (SQL instance) */
	@CommittedMemoryGB						[CommittedMemoryGB],
	@CommittedTargetMemoryGB				[CommittedTargetMemoryGB],
	@MemoryUsedPercentage					[MemoryUsedPercentage],
	@SQLMemoryModelDesc						[SQLMemoryModelDesc],


	/* edition */
	@Edition								[Edition],
	@EditionID								[EditionID],
	@EngineEdition							[EngineEdition],
	@EngineEditionDesc						[EngineEditionDesc],

	/* version */
	@BuildCLRVersion						[BuildCLRVersion],
	@ProductBuild							[ProductBuild],
	@ProductBuildType						[ProductBuildType],
	@ProductLevel							[ProductLevel],
	@ProductUpdateLevel						[ProductUpdateLevel],
	@ProductVersion							[ProductVersion],
	@ProductMajorVersion					[ProductMajorVersion],
	@ProductMinorVersion					[ProductMinorVersion],
	@ProductUpdateReference					[ProductUpdateReference],
	@VersionFullDesc						[VersionFullDesc],

	/* features */
	@IsLocalDB								[IsLocalDB],
	@IsFullTextInstalled					[IsFullTextInstalled],
	@IsAdvancedAnalyticsInstalled			[IsAdvancedAnalyticsInstalled],
	@IsPolybaseInstalled					[IsPolybaseInstalled],
	@IsXTPSupported							[IsXTPSupported],

	/* cluster and hadr */
	@IsClustered							[IsClustered],
	@IsHadrEnabled							[IsHadrEnabled],	
	@HadrManagerStatus						[HadrManagerStatus],

	/* collation */
	@Collation								[Collation],
	@CollationID							[CollationID],
	@ComparisonStyle						[ComparisonStyle],
	@LCID									[LCID],
	@SqlCharSet								[SqlCharSet],
	@SqlCharSetName							[SqlCharSetName],
	@SqlSortOrder							[SqlSortOrder],
	@SqlSortOrderName						[SqlSortOrderName],

	/* filestream */
	@FilestreamShareName					[FilestreamShareName],
	@FilestreamConfiguredLevel				[FilestreamConfiguredLevel],
	@FilestreamEffectiveLevel				[FilestreamEffectiveLevel],

	/* resource database */
	@ResourceVersion						[ResourceVersion],
	@ResourceLastUpdateDateTime				[ResourceLastUpdateDateTime],

	/* server config options */
	@ServerConfigOptionsLine				[ServerConfigOptions]


end			/* line section end */





/********* Multiselect *********/

/* output several result sets */
if @command in ('multiselect') begin


/* server */
select 
	@ServerName								[ServerName],
	@MachineName							[MachineName],
	@ComputerNamePhysicalNetBios			[ComputerNamePhysicalNetBios],
	@VirtualMachineType						[VirtualMachineType],
	@ContainerTypeDesc						[ContainerTypeDesc]


/* host os info */
select
	@HostPlatform							[HostPlatform],
	@HostDistribution						[HostDistribution],
	@HostRelease							[HostRelease],
	@HostArchitecture						[HostArchitecture]


/* cpu (machine) */
select	
	@SocketCount							[SocketCount],
	@CoresPerSocket							[CoresPerSocket],
	@HyperThreadRatio						[HyperThreadRatio],
	@LogicalCPUCount						[LogicalCPUCount],
	@NumaNodeCount							[NumaNodeCount]
	

/* memory (machine) */
select	
	@VirtualMemoryGB						[VirtualMemoryGB],
	@PhysicalMemoryGB						[PhysicalMemoryGB],
	@AvailablePhysicalMemoryGB				[AvailablePhysicalMemoryGB],
	@PageFileGB								[PageFileGB],
	@AvailablePageFileGB					[AvailablePageFileGB],
	@SystemCacheGB							[SystemCacheGB],
	@KernelPagedPoolGB						[KernelPagedPoolGB],
	@KernelNonPagedPoolGB					[KernelNonPagedPoolGB],
	@SystemMemoryState						[SystemMemoryState]
		

/* sql instance */
select	
	@InstanceName							[InstanceName],
	@ServiceName							[ServiceName],
	@SQLServerStartTime						[SQLServerStartTime],
	@ProcessID								[ProcessID],
	@Language								[Language],
	@InstanceDefaultDataPath				[InstanceDefaultDataPath],
	@InstanceDefaultLogPath					[InstanceDefaultLogPath],
	@IsIntegratedSecurityOnly				[IsIntegratedSecurityOnly],
	@IsSingleUser							[IsSingleUser],
	@MaxConnections							[MaxConnections],
	@MaxPrecision							[MaxPrecision]
	
	

/* cpu (sql instance) */
select
	@MaxDOP									[MaxDOP],
	@CPURateAzureSQL						[CPURateAzureSQL],
	@SchedulerCount							[SchedulerCount],
	@SchedulerTotalCount					[SchedulerTotalCount],
	@MaxWorkersCount						[MaxWorkersCount]
	

/* memory (sql instance) */
select
	@CommittedMemoryGB						[CommittedMemoryGB],
	@CommittedTargetMemoryGB				[CommittedTargetMemoryGB],
	@MemoryUsedPercentage					[MemoryUsedPercentage],
	@SQLMemoryModelDesc						[SQLMemoryModelDesc]


/* edition */
select
	@Edition								[Edition],
	@EditionID								[EditionID],
	@EngineEdition							[EngineEdition],
	@EngineEditionDesc						[EngineEditionDesc]


/* version */
select	
	@BuildCLRVersion						[BuildCLRVersion],
	@ProductBuild							[ProductBuild],
	@ProductBuildType						[ProductBuildType],
	@ProductLevel							[ProductLevel],
	@ProductUpdateLevel						[ProductUpdateLevel],
	@ProductVersion							[ProductVersion],
	@ProductMajorVersion					[ProductMajorVersion],
	@ProductMinorVersion					[ProductMinorVersion],
	@ProductUpdateReference					[ProductUpdateReference],
	@VersionFullDesc						[VersionFullDesc]


/* features */
select
	@IsLocalDB								[IsLocalDB],
	@IsFullTextInstalled					[IsFullTextInstalled],
	@IsAdvancedAnalyticsInstalled			[IsAdvancedAnalyticsInstalled],
	@IsPolybaseInstalled					[IsPolybaseInstalled],
	@IsXTPSupported							[IsXTPSupported]


/* cluster and hard */
select	
	@IsClustered							[IsClustered],
	@IsHadrEnabled							[IsHadrEnabled],	
	@HadrManagerStatus						[HadrManagerStatus]


/* collation */
select	
	@Collation								[Collation],
	@CollationID							[CollationID],
	@ComparisonStyle						[ComparisonStyle],
	@LCID									[LCID],
	@SqlCharSet								[SqlCharSet],
	@SqlCharSetName							[SqlCharSetName],
	@SqlSortOrder							[SqlSortOrder],
	@SqlSortOrderName						[SqlSortOrderName]


/* filestream */
select	
	@FilestreamShareName					[FilestreamShareName],
	@FilestreamConfiguredLevel				[FilestreamConfiguredLevel],
	@FilestreamEffectiveLevel				[FilestreamEffectiveLevel]

/* resource database */
select
	@ResourceVersion						[ResourceVersion],
	@ResourceLastUpdateDateTime				[ResourceLastUpdateDateTime]


/* server config options */
select
	@ServerConfigOptionsLine				[ServerConfigOptions]

	
end			/* multiselect section end */





/********* Table *********/


if @command in ('all','table','print') begin

	if object_id ('tempdb..#ServerProperties') is not null drop table #ServerProperties

	create table #ServerProperties (
		ID						int identity primary key,

		PropertyName			varchar(100),
		PropertyValue			varchar(300),

		PropertyNameValue		varchar(400) default '')


	/* server */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('',''),
			('/* Server */',''),
			('',''),
			('Server Name',@ServerName),
			('Machine Name',@MachineName),
			('Computer Name Physical Net Bios',@ComputerNamePhysicalNetBios),
			('Virtual Machine Type',@VirtualMachineType),
			('Container Type Desc',@ContainerTypeDesc),
			('','')


	/* host os */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Host OS */',''),
			('',''),
			('Host Platform',@HostPlatform),
			('Host Distribution',@HostDistribution),
			('Host Release',@HostRelease),
			('Host Service Pack Level',@HostServicePackLevel),
			('Host SKU',@HostSKU),
			('OS Language Version',@OSLanguageVersion),
			('Host Architecture',@HostArchitecture),
			('','')


	/* cpu (machine) */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* CPU (Machine) */',''),
			('',''),
			('Socket Count',@SocketCount),
			('Cores Per Socket',@CoresPerSocket),
			('Hyper-Thread Ratio',@HyperThreadRatio),
			('Logical CPU Count',@LogicalCPUCount),
			('NUMA Node Count',@NumaNodeCount),
			('','')
		
	
	/* memory (machine) */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Memory (Machine) */',''),
			('',''),
			('Virtual Memory GB',@VirtualMemoryGB),
			('Physical Memory GB',@PhysicalMemoryGB),	
			('Available Physical Memory GB',@AvailablePhysicalMemoryGB),
			('Page File GB',@PageFileGB),
			('Available Page File GB',@AvailablePageFileGB),
			('System Cache GB',@SystemCacheGB),
			('Kernel Paged Pool GB',@KernelPagedPoolGB),
			('Kernel Non Paged Pool GB',@KernelNonPagedPoolGB),
			('System Memory State',@SystemMemoryState),
			('','')
			
								
	/* sql instance */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* SQL Server Instance */',''),
			('',''),			
			('Instance Name',@InstanceName),
			('Service Name',@ServiceName),
			('SQL Server Start Time',@SQLServerStartTime),
			('Process ID',@ProcessID),
			('Language',@Language),
			('Instance Default Data Path',@InstanceDefaultDataPath),
			('Instance Default Log Path',@InstanceDefaultLogPath),
			('Is Integrated Security Only',@IsIntegratedSecurityOnly),
			('Is Single User',@IsSingleUser),
			('Max Connections',@MaxConnections),
			('Max Precision',@MaxPrecision),
			('','')


	/* cpu (sql instance) */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* CPU (SQL Instance) */',''),
			('',''),
			('Max Degree Of Paralellism',@MaxDOP),
			('CPU Rate (Azure SQL)',@CPURateAzureSQL),
			('Scheduler Count',@SchedulerCount),
			('Scheduler Count',@SchedulerCount),
			('Scheduler Total Count',@SchedulerTotalCount),
			('Max Workers Count',@MaxWorkersCount),
			('','')


	/* memory (sql instance) */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Memory (SQL Instance) */',''),
			('','')

	if @EngineEdition = '5' begin
		insert into #ServerProperties (PropertyName,PropertyValue)
		values	('Memory Limit Azure SQL DB (GB)',@ProcessMemoryLimitGB)
		
	end

	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('Target Server Memory GB (limit for SQL)',@CommittedTargetMemoryGB),
			('Total Memory GB (consumed by SQL)',@CommittedMemoryGB),
			('Memory Used Percentage',@MemoryUsedPercentage),
			('SQL Memory Model Desc',@SQLMemoryModelDesc),
			('','')

	/* edition */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Instance Edition */',''),
			('',''),
			('Edition',@Edition),
			('Edition ID',@EditionID),
			('Engine Edition',@EngineEdition),
			('Engine Edition Desc',@EngineEditionDesc),
			('','')


	/* version */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Instance Version */',''),
			('',''),
			('Build CLR Version',@BuildCLRVersion),
			('Product Build',@ProductBuild),
			('Product Build Type',@ProductBuildType),
			('Product Level',@ProductLevel),
			('Product Update Level',@ProductUpdateLevel),
			('Product Version',@ProductVersion),
			('Product Major Version',@ProductMajorVersion),
			('Product Minor Version',@ProductMinorVersion),
			('Product Update Reference',@ProductUpdateReference),
			('Version Full Description',@VersionFullDesc),
			('','')


	/* features */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/*  Instance Features */',''),
			('',''),
			('Is Local DB',@IsLocalDB),
			('Is Full Text Installed',@IsFullTextInstalled),
			('Is Advanced Analytics Installed',@IsAdvancedAnalyticsInstalled),
			('Is Polybase Installed',@IsPolybaseInstalled),
			('Is XTP Supported',@IsXTPSupported),
			('','')


	/* cluster and hadr */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Cluster and HADR */',''),
			('',''),
			('Is Clustered',@IsClustered),
			('Is Hadr Enabled',@IsHadrEnabled),
			('Hadr Manager Status',@HadrManagerStatus),
			('','')

		
	/* collation */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Instance Collation */',''),
			('',''),
			('Collation',@Collation),
			('Collation ID',@CollationID),
			('LCID',@LCID),
			('Sql Char Set',@SqlCharSet),
			('Sql Char Set Name',@SqlCharSetName),
			('Sql Sort Order',@SqlSortOrder),
			('Sql Sort Order Name',@SqlSortOrderName),
			('','')


	/* filestream */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Instace Filestream */',''),
			('',''),
			('Filestream Share Name',@FilestreamShareName),
			('Filestream Configured Level',@FilestreamConfiguredLevel),
			('Filestream Effective Level',@FilestreamEffectiveLevel),
			('','')


	/* resource database */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Instance Resource Database */',''),
			('',''),
			('Resource Version',@ResourceVersion),
			('Resource Last Update Date Time',@ResourceLastUpdateDateTime),
			('','')


	/* server config options */
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('/* Server Config Options */',''),
			('','')

	insert into #ServerProperties (PropertyName,PropertyValue)
	select ConfigOptionName, CurrentValue
	from @ServerConfigOptions

 
	/* show table data */
	if @command in ('all','table') begin
		select PropertyName, PropertyValue 
		from #ServerProperties
	end

end				/* table section end */




/************* Print ************/

if @command in ('all','print') begin

	/* combined line */
	update #ServerProperties
		set PropertyNameValue = PropertyName + ': ' + PropertyValue
	where PropertyName <> '' and PropertyName not like '-- %'

	update #ServerProperties
		set PropertyNameValue = PropertyName 
	where PropertyName like '-- %'


	/* fill text variable for print */
	declare 
		@counter int = 2, 
		@print varchar(max) = ''
	
	while @counter <= (select max(ID) from #ServerProperties) begin
		set @print = @print + (select PropertyNameValue from #ServerProperties where ID = @counter) + '
	'
		set @counter += 1
	end
	

	/* print the result */
	print @print

end				/* print section end */


end