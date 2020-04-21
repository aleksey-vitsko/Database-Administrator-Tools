
-- use master
create or alter procedure ViewServerProperties (@command varchar(20) = 'all')  
as begin 

/****************************************** ViewServerProperties procedure ***********************************************

Author: Aleksey Vitsko
Created: July 2018

Description: shows server instance level properties 
Example: exec ViewServerProperties


--------------------------------------------------------------------------------------------------------------------------

Accepts arguments (@command):

'all'					-- line, table, print commands are used
'line'					-- output is a single row with many columns
'multiselect'			-- output is several result sets
'table'					-- output is in table format
'print'					-- output is printed 

--------------------------------------------------------------------------------------------------------------------------

Version: 1.03

Change history:

2019-05-31 - Aleksey Vitsko - added more CPU and Memory information in the output (number of sockets, used memory, virtual memory etc.)
2018-07-24 - Aleksey Vitsko - added server config options (sp_configure) to the output
2018-07-21 - Aleksey Vitsko - added machine specs to the output
2018-07-19 - Aleksey Vitsko - Created procedure

*************************************************************************************************************************/


set nocount on

---------------------------------------------------- Variables -------------------------------------------------------

-- variables to keep server properties in text format
declare 
	
	-- machine specs
	@CPUCount								varchar(300) = 'n/a',
	@HyperThreadRatio						varchar(300) = 'n/a',
	@SocketCount							varchar(300) = 'n/a',
	@CoresPerSocket							varchar(300) = 'n/a',
	
	@PhysicalMemoryGB						varchar(300) = 'n/a',
	@VirtualMemoryGB						varchar(300) = 'n/a',
	@CommittedMemoryGB						varchar(300) = 'n/a',
	@CommittedTargetMemoryGB				varchar(300) = 'n/a',
	@MemoryUsedPercentage								varchar(300) = 'n/a',
	@SQLMemoryModelDesc						varchar(300) = 'n/a',

	@SQLServerStartTime						varchar(300) = 'n/a',
	@VirtualMachineType						varchar(300) = 'n/a',
	
	-- machine name
	@ComputerNamePhysicalNetBios			varchar(300) = cast(isnull(serverproperty('ComputerNamePhysicalNetBios'),'n/a') as varchar(300)),
	@MachineName							varchar(300) = cast(isnull(serverproperty('MachineName'),'n/a')	 as varchar(300)),
	@ServerName								varchar(300) = cast(serverproperty('ServerName') as varchar(300)),

	-- instance
	@ProcessID								varchar(300) = cast(isnull(serverproperty('ProcessID'),'n/a') as varchar(300)),
	@InstanceName							varchar(300) = cast(isnull(serverproperty('InstanceName'),'(default)') as varchar(300)),
	@ServiceName							varchar(300) = 'n/a', -- = @@SERVICENAME,
	@Language								varchar(300) = cast(@@LANGUAGE as varchar(300)),
	@InstanceDefaultDataPath				varchar(300) = cast(isnull(serverproperty('InstanceDefaultDataPath'),'n/a') as varchar(300)),
	@InstanceDefaultLogPath					varchar(300) = cast(isnull(serverproperty('InstanceDefaultLogPath'),'n/a') as varchar(300)),
	@IsIntegratedSecurityOnly				varchar(300) = cast(serverproperty('IsIntegratedSecurityOnly') as varchar(300)),
	@IsSingleUser							varchar(300) = cast(serverproperty('IsSingleUser') as varchar(300)),
	@MaxConnections							varchar(300) = cast(@@MAX_CONNECTIONS as varchar(300)),
	@MaxPrecision							varchar(300) = cast(@@MAX_PRECISION as varchar(300)),
			
	-- edition
	@Edition								varchar(300) = cast(serverproperty('Edition') as varchar(300)),
	@EditionID								varchar(300) = cast(serverproperty('EditionID')	 as varchar(300)),
	@EngineEdition							varchar(300) = cast(serverproperty('EngineEdition') as varchar(300)),
	@EngineEditionDesc						varchar(300),
	
	-- version
	@BuildCLRVersion						varchar(300) = cast(isnull(serverproperty('BuildCLRVersion'),'n/a') as varchar(300)),
	@ProductBuild							varchar(300) = cast(serverproperty('ProductBuild') as varchar(300)),
	@ProductBuildType						varchar(300) = cast(isnull(serverproperty('ProductBuildType'),'n/a') as varchar(300)),
	@ProductLevel							varchar(300) = cast(serverproperty('ProductLevel') as varchar(300)),
	@ProductUpdateLevel						varchar(300) = cast(isnull(serverproperty('ProductUpdateLevel'),'n/a') as varchar(300)),
	@ProductVersion							varchar(300) = cast(serverproperty('ProductVersion') as varchar(300)),
	@ProductMajorVersion					varchar(300) = cast(serverproperty('ProductMajorVersion') as varchar(300)),
	@ProductMinorVersion					varchar(300) = cast(serverproperty('ProductMinorVersion') as varchar(300)),
	@ProductUpdateReference					varchar(300) = cast(isnull(serverproperty('ProductUpdateReference'),'n/a') as varchar(300)),
	@VersionFullDesc						varchar(300) = cast(@@VERSION as varchar(300)),

	-- features	
	@IsLocalDB								varchar(300) = cast(isnull(serverproperty('IsLocalDB'),'n/a') as varchar(300)),
	@IsFullTextInstalled					varchar(300) = cast(serverproperty('IsFullTextInstalled') as varchar(300)),
	@IsAdvancedAnalyticsInstalled			varchar(300) = cast(isnull(serverproperty('IsAdvancedAnalyticsInstalled'),'n/a') as varchar(300)),
	@IsPolybaseInstalled					varchar(300) = cast(isnull(serverproperty('IsPolybaseInstalled'),'n/a') as varchar(300)),
	@IsXTPSupported							varchar(300) = cast(isnull(serverproperty('IsXTPSupported'),'n/a') as varchar(300)),

	-- cluster and hadr
	@IsClustered							varchar(300) = cast(isnull(serverproperty('IsClustered'),'n/a') as varchar(300)),
	@IsHadrEnabled							varchar(300) = cast(isnull(serverproperty('IsHadrEnabled'),'n/a') as varchar(300)),
	@HadrManagerStatus						varchar(300) = cast(isnull(serverproperty('HadrManagerStatus'),'n/a') as varchar(300)),
	
	-- collation
	@Collation								varchar(300) = cast(serverproperty('Collation') as varchar(300)),
	@CollationID							varchar(300) = cast(serverproperty('CollationID') as varchar(300)),
	@ComparisonStyle						varchar(300) = cast(serverproperty('ComparisonStyle') as varchar(300)),
	@LCID									varchar(300) = cast(serverproperty('LCID') as varchar(300)),
	@SqlCharSet								varchar(300) = cast(serverproperty('SqlCharSet') as varchar(300)),
	@SqlCharSetName							varchar(300) = cast(serverproperty('SqlCharSetName') as varchar(300)),
	@SqlSortOrder							varchar(300) = cast(serverproperty('SqlSortOrder') as varchar(300)),
	@SqlSortOrderName						varchar(300) = cast(serverproperty('SqlSortOrderName') as varchar(300)),
	
	-- filestream
	@FilestreamShareName					varchar(300) = cast(isnull(serverproperty('FilestreamShareName'),'n/a') as varchar(300)),
	@FilestreamConfiguredLevel				varchar(300) = cast(serverproperty('FilestreamConfiguredLevel')	 as varchar(300)),
	@FilestreamEffectiveLevel				varchar(300) = cast(serverproperty('FilestreamEffectiveLevel') as varchar(300)),
	
	-- resource database
	@ResourceVersion						varchar(300) = cast(serverproperty('ResourceVersion') as varchar(300)),
	@ResourceLastUpdateDateTime				varchar(300) = cast(serverproperty('ResourceLastUpdateDateTime') as varchar(300)),

	-- server config options
	@ServerConfigOptionsLine				varchar(max) = ''

	



-- engine edition description
set @EngineEditionDesc = case @EngineEdition
	when '1' then 'Personal or Desktop'
	when '2' then 'Standard'
	when '3' then 'Enterprise'
	when '4' then 'Express'
	when '5' then 'SQL Database'
	when '6' then 'SQL Data Warehouse'
	when '8' then 'Managed Instance'
end





-- machine specs and service name 
if @EngineEdition not in ('5','6','8') begin

	-- machine 
	select
		@CPUCount						= cast(cpu_count as varchar(300)),
		@HyperThreadRatio				= cast(hyperthread_ratio as varchar(300)),
		@SocketCount					= cast(socket_count as varchar(300)),
		@CoresPerSocket					= cast(cores_per_socket as varchar(300)),
		
		@PhysicalMemoryGB				= cast((physical_memory_kb / 1048576) as varchar(300)),
		@VirtualMemoryGB				= cast((virtual_memory_kb / 1048576) as varchar(300)), 	

		@CommittedMemoryGB				= substring(cast((cast(committed_kb as decimal(20,2)) / 1024 / 1024) as varchar(300)),1,charindex('.',cast((cast(committed_kb as decimal(20,2)) / 1024 / 1024) as varchar(300))) + 2),
		@CommittedTargetMemoryGB		= substring(cast((cast(committed_target_kb as decimal(20,2)) / 1024 / 1024) as varchar(300)),1,charindex('.',cast((cast(committed_target_kb as decimal(20,2)) / 1024 / 1024) as varchar(300))) + 2),
		
		@SQLMemoryModelDesc				= cast(sql_memory_model_desc as varchar(300)), 	
		@MemoryUsedPercentage			= substring(cast((cast(committed_kb as decimal(20,2)) / cast(committed_target_kb  as decimal(20,2)) * 100) as varchar),1,5) + ' %',
		
		@SQLServerStartTime				= cast(sqlserver_start_time as varchar(300)),
		@VirtualMachineType				= cast(virtual_machine_type_desc as varchar(300))
	from sys.dm_os_sys_info
	
	
	/*
	set @CPUCount				= cast((select cpu_count from sys.dm_os_sys_info) as varchar(300))
	set	@HyperThreadRatio		= cast((select hyperthread_ratio from sys.dm_os_sys_info) as varchar(300))
	set	@PhysicalMemoryGB		= cast((select physical_memory_kb / 1048576 from sys.dm_os_sys_info) as varchar(300))
	set	@SQLServerStartTime		= cast((select sqlserver_start_time from sys.dm_os_sys_info) as varchar(300))
	set	@VirtualMachineType		= cast((select virtual_machine_type_desc from sys.dm_os_sys_info) as varchar(300))
	*/

	-- service name
	declare @exec varchar(max)

	set @exec = 'create table ##ServiceName_global (tServiceName varchar(300)) 
	insert into ##ServiceName_global (tServiceName) 
	select @@SERVICENAME'

	exec(@exec)
	set @ServiceName = (select top 1 tServiceName from ##ServiceName_global)
	drop table ##ServiceName_global


	-- server config options
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




---------------------------------------------------- Line -------------------------------------------------------

-- output line
if @command in ('all','line') begin

select 
	-- machine specs
	@CPUCount								[CPUCount],
	@SocketCount							[SocketCount],
	@CoresPerSocket							[CoresPerSocket],
	@HyperThreadRatio						[HyperThreadRatio],

	@PhysicalMemoryGB						[PhysicalMemoryGB],
	@VirtualMemoryGB						[VirtualMemoryGB],
	@CommittedMemoryGB						[CommittedMemoryGB],
	@CommittedTargetMemoryGB				[CommittedTargetMemoryGB],
	@MemoryUsedPercentage					[MemoryUsedPercentage],
	@SQLMemoryModelDesc						[SQLMemoryModelDesc],

	@SQLServerStartTime						[SQLServerStartTime],
	@VirtualMachineType						[VirtualMachineType],

	-- machine name
	@MachineName							[MachineName],
	@ServerName								[ServerName],
	@ComputerNamePhysicalNetBios			[ComputerNamePhysicalNetBios],

	-- instance
	@ProcessID								[ProcessID],
	@InstanceName							[InstanceName],
	@ServiceName							[ServiceName],
	@Language								[Language],
	@InstanceDefaultDataPath				[InstanceDefaultDataPath],
	@InstanceDefaultLogPath					[InstanceDefaultLogPath],
	@IsIntegratedSecurityOnly				[IsIntegratedSecurityOnly],
	@IsSingleUser							[IsSingleUser],
	@MaxConnections							[MaxConnections],
	@MaxPrecision							[MaxPrecision],

	-- edition
	@Edition								[Edition],
	@EditionID								[EditionID],
	@EngineEdition							[EngineEdition],
	@EngineEditionDesc						[EngineEditionDesc],

	-- version
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

	-- features
	@IsLocalDB								[IsLocalDB],
	@IsFullTextInstalled					[IsFullTextInstalled],
	@IsAdvancedAnalyticsInstalled			[IsAdvancedAnalyticsInstalled],
	@IsPolybaseInstalled					[IsPolybaseInstalled],
	@IsXTPSupported							[IsXTPSupported],

	-- cluster and hard
	@IsClustered							[IsClustered],
	@IsHadrEnabled							[IsHadrEnabled],	
	@HadrManagerStatus						[HadrManagerStatus],

	-- collation
	@Collation								[Collation],
	@CollationID							[CollationID],
	@ComparisonStyle						[ComparisonStyle],
	@LCID									[LCID],
	@SqlCharSet								[SqlCharSet],
	@SqlCharSetName							[SqlCharSetName],
	@SqlSortOrder							[SqlSortOrder],
	@SqlSortOrderName						[SqlSortOrderName],

	-- filestream
	@FilestreamShareName					[FilestreamShareName],
	@FilestreamConfiguredLevel				[FilestreamConfiguredLevel],
	@FilestreamEffectiveLevel				[FilestreamEffectiveLevel],

	-- resource database
	@ResourceVersion						[ResourceVersion],
	@ResourceLastUpdateDateTime				[ResourceLastUpdateDateTime],

	-- server config options
	@ServerConfigOptionsLine				[ServerConfigOptions]


end			-- line section end






---------------------------------------------------- Multiselect -------------------------------------------------------

-- output several result sets
if @command in ('multiselect') begin


-- machine specs
select
	@CPUCount								[CPUCount],
	@SocketCount							[SocketCount],
	@CoresPerSocket							[CoresPerSocket],
	@HyperThreadRatio						[HyperThreadRatio],
	
	
	@PhysicalMemoryGB						[PhysicalMemoryGB],
	@VirtualMemoryGB						[VirtualMemoryGB],
	@CommittedMemoryGB						[CommittedMemoryGB],
	@CommittedTargetMemoryGB				[CommittedTargetMemoryGB],
	@MemoryUsedPercentage					[MemoryUsedPercentage],
	@SQLMemoryModelDesc						[SQLMemoryModelDesc],
	
	@SQLServerStartTime						[SQLServerStartTime],
	@VirtualMachineType						[VirtualMachineType]


-- machine name
select 
	@MachineName							[MachineName],
	@ServerName								[ServerName],
	@ComputerNamePhysicalNetBios			[ComputerNamePhysicalNetBios]


-- instance
select	
	@ProcessID								[ProcessID],
	@InstanceName							[InstanceName],
	@ServiceName							[ServiceName],
	@Language								[Language],
	@InstanceDefaultDataPath				[InstanceDefaultDataPath],
	@InstanceDefaultLogPath					[InstanceDefaultLogPath],
	@IsIntegratedSecurityOnly				[IsIntegratedSecurityOnly],
	@IsSingleUser							[IsSingleUser],
	@MaxConnections							[MaxConnections],
	@MaxPrecision							[MaxPrecision]


-- edition
select
	@Edition								[Edition],
	@EditionID								[EditionID],
	@EngineEdition							[EngineEdition],
	@EngineEditionDesc						[EngineEditionDesc]


-- version
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


-- features
select
	@IsLocalDB								[IsLocalDB],
	@IsFullTextInstalled					[IsFullTextInstalled],
	@IsAdvancedAnalyticsInstalled			[IsAdvancedAnalyticsInstalled],
	@IsPolybaseInstalled					[IsPolybaseInstalled],
	@IsXTPSupported							[IsXTPSupported]


-- cluster and hard
select	
	@IsClustered							[IsClustered],
	@IsHadrEnabled							[IsHadrEnabled],	
	@HadrManagerStatus						[HadrManagerStatus]


-- collation
select	
	@Collation								[Collation],
	@CollationID							[CollationID],
	@ComparisonStyle						[ComparisonStyle],
	@LCID									[LCID],
	@SqlCharSet								[SqlCharSet],
	@SqlCharSetName							[SqlCharSetName],
	@SqlSortOrder							[SqlSortOrder],
	@SqlSortOrderName						[SqlSortOrderName]


-- filestream
select	
	@FilestreamShareName					[FilestreamShareName],
	@FilestreamConfiguredLevel				[FilestreamConfiguredLevel],
	@FilestreamEffectiveLevel				[FilestreamEffectiveLevel]

-- resource database
select
	@ResourceVersion						[ResourceVersion],
	@ResourceLastUpdateDateTime				[ResourceLastUpdateDateTime]


-- server config options
select
	@ServerConfigOptionsLine				[ServerConfigOptions]

	
end			-- multiselect section end





---------------------------------------------------- Table -------------------------------------------------------


if @command in ('all','table','print') begin

	if object_id ('tempdb..#ServerProperties') is not null drop table #ServerProperties

	create table #ServerProperties (
		ID						int identity primary key,

		PropertyName			varchar(100),
		PropertyValue			varchar(300),

		PropertyNameValue		varchar(400) default '')



	-- server
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('',''),
			('-- Server Machine --',''),
			('',''),
			('CPUCount',@CPUCount),
			('SocketCount',@SocketCount),
			('CoresPerSocket',@CoresPerSocket),
			('HyperThreadRatio',@HyperThreadRatio),
			
			('PhysicalMemoryGB',@PhysicalMemoryGB),
			('VirtualMemoryGB',@VirtualMemoryGB),
			('CommittedMemoryGB',@CommittedMemoryGB),
			('CommittedTargetMemoryGB',@CommittedTargetMemoryGB),
			('MemoryUsedPercentage',@MemoryUsedPercentage),
			('SQLMemoryModelDesc',@SQLMemoryModelDesc),

			('SQLServerStartTime',@SQLServerStartTime),
			('VirtualMachineType',@VirtualMachineType),
			('ServerName',@ServerName),
			('MachineName',@MachineName),
			('ComputerNamePhysicalNetBios',@ComputerNamePhysicalNetBios),
			('','')
		
		
	-- instance
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('-- SQL Server Instance --',''),
			('',''),
			('ProcessID',@ProcessID),
			('InstanceName',@InstanceName),
			('ServiceName',@ServiceName),
			('Language',@Language),
			('InstanceDefaultDataPath',@InstanceDefaultDataPath),
			('InstanceDefaultLogPath',@InstanceDefaultLogPath),
			('IsIntegratedSecurityOnly',@IsIntegratedSecurityOnly),
			('IsSingleUser',@IsSingleUser),
			('MaxConnections',@MaxConnections),
			('MaxPrecision',@MaxPrecision),
			('','')


	-- edition
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('-- Instance Edition --',''),
			('',''),
			('Edition',@Edition),
			('EditionID',@EditionID),
			('EngineEdition',@EngineEdition),
			('EngineEditionDesc',@EngineEditionDesc),
			('','')


	-- version
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('-- Instance Version --',''),
			('',''),
			('BuildCLRVersion',@BuildCLRVersion),
			('ProductBuild',@ProductBuild),
			('ProductBuildType',@ProductBuildType),
			('ProductLevel',@ProductLevel),
			('ProductUpdateLevel',@ProductUpdateLevel),
			('ProductVersion',@ProductVersion),
			('ProductMajorVersion',@ProductMajorVersion),
			('ProductMinorVersion',@ProductMinorVersion),
			('ProductUpdateReference',@ProductUpdateReference),
			('VersionFullDescription',@VersionFullDesc),
			('','')


	-- features
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('--  Instance Features --',''),
			('',''),
			('IsLocalDB',@IsLocalDB),
			('IsFullTextInstalled',@IsFullTextInstalled),
			('IsAdvancedAnalyticsInstalled',@IsAdvancedAnalyticsInstalled),
			('IsPolybaseInstalled',@IsPolybaseInstalled),
			('IsXTPSupported',@IsXTPSupported),
			('','')


	-- cluster and hadr
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('-- Cluster and HADR --',''),
			('',''),
			('IsClustered',@IsClustered),
			('IsHadrEnabled',@IsHadrEnabled),
			('HadrManagerStatus',@HadrManagerStatus),
			('','')

		
	-- collation
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('-- Instance Collation --',''),
			('',''),
			('Collation',@Collation),
			('CollationID',@CollationID),
			('LCID',@LCID),
			('SqlCharSet',@SqlCharSet),
			('SqlCharSetName',@SqlCharSetName),
			('SqlSortOrder',@SqlSortOrder),
			('SqlSortOrderName',@SqlSortOrderName),
			('','')


	-- filestream
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('-- Instace Filestream --',''),
			('',''),
			('FilestreamShareName',@FilestreamShareName),
			('FilestreamConfiguredLevel',@FilestreamConfiguredLevel),
			('FilestreamEffectiveLevel',@FilestreamEffectiveLevel),
			('','')


	-- resource database
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('-- Instance Resource Database --',''),
			('',''),
			('ResourceVersion',@ResourceVersion),
			('ResourceLastUpdateDateTime',@ResourceLastUpdateDateTime),
			('','')


	-- server config options
	insert into #ServerProperties (PropertyName,PropertyValue)
	values	('-- Server Config Options --',''),
			('','')

	insert into #ServerProperties (PropertyName,PropertyValue)
	select ConfigOptionName, CurrentValue
	from @ServerConfigOptions

 
	-- show table data 
	if @command in ('all','table') begin
		select PropertyName, PropertyValue 
		from #ServerProperties
	end

end				-- table section end





---------------------------------------------------- Print -------------------------------------------------------

if @command in ('all','print') begin


-- combined line
update #ServerProperties
	set PropertyNameValue = PropertyName + ': ' + PropertyValue
where PropertyName <> '' and PropertyName not like '-- %'

update #ServerProperties
	set PropertyNameValue = PropertyName 
where PropertyName like '-- %'


-- fill text variable for print
declare 
	@counter int = 2, 
	@print varchar(max) = ''
	
while @counter <= (select max(ID) from #ServerProperties) begin
	set @print = @print + (select PropertyNameValue from #ServerProperties where ID = @counter) + '
'
	set @counter += 1
end
	

-- print the result
print @print

end				-- print section end


end