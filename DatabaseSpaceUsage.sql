

create or alter procedure DatabaseSpaceUsage (
	@DatabaseName					nvarchar(128)	= '',
	@ExpertMode						smallint = 0
	)
as begin



/****************************************************************** DATABASE SPACE USAGE PROCEDURE **************************************************************

Author: Aleksey Vitsko


Version: 2.1.3

Description: 

For a given database, shows how much space is used by:

- data (heap, clustered)
- indexes (NCI, CCI, NCCI, XML, JSON, Spatial, NCI Hash)
- reserved space

On database and table levels.
All numbers are in megabytes, with two digits precision.


History:

2026-09-18 -> Aleksey Vitsko - correction: "free" -> "used" percent
2026-08-31 -> Aleksey Vitsko - updated description; added "tested on" section.
2026-08-31 -> Aleksey Vitsko - added total database size, percent of free space, table count
2026-08-28 -> Aleksey Vitsko - created stored procedure v2


Tested on:

- SQL Server 2016 (SP2), 2017 (RTM), 2019 (RTM), 2022 (RTM), 2025 (RTM)
- Azure SQL Managed Instance (SQL 2022 update policy)
- Azure SQL Database


*****************************************************************************************************************************************************************/

set nocount on



/* if database name is not specified, use current db */
if @DatabaseName = '' begin
	
	set @DatabaseName = db_name()

end

/* check if supplied @DatabaseName exists in sys.databases */
if not exists (select * from sys.databases where [name] = @DatabaseName) begin

	print 'Supplied @DatabaseName value doesn''t exist in sys.databases
Please specify name of the existing database.

Exiting...'

	return
end
	

/* ExpertMode validation */
if @ExpertMode not in (0,1) begin
	print '@ExpertMode can only be 0 or 1.

Exiting...'

	return

end



/* variables */
declare 
	@SQL						nvarchar(max),
	
	@total_data_file_mb			decimal(38,2),
	@total_allocated_mb			decimal(38,2),
	@total_used_space_pct		varchar(10),

	@table_count				int


/* main temp table holding list of tables */
drop table if exists #Tables 

create table #Tables (
	ID							int identity primary key,
	[object_id]					bigint,
	[schema_name]				nvarchar(128),
	table_name					nvarchar(128),

	row_count					bigint,

	heap_used_mb				decimal(38,2) default 0,
	heap_reserved_mb			decimal(38,2) default 0,

	CI_used_mb					decimal(38,2) default 0,
	CI_reserved_mb				decimal(38,2) default 0,

	NCI_used_mb					decimal(38,2) default 0,
	NCI_reserved_mb				decimal(38,2) default 0,

	CCI_used_mb					decimal(38,2) default 0,
	CCI_reserved_mb				decimal(38,2) default 0,

	NCCI_used_mb				decimal(38,2) default 0,
	NCCI_reserved_mb			decimal(38,2) default 0,

	XML_used_mb					decimal(38,2) default 0,
	XML_reserved_mb				decimal(38,2) default 0,

	spatial_used_mb				decimal(38,2) default 0,
	spatial_reserved_mb			decimal(38,2) default 0,

	JSON_used_mb				decimal(38,2) default 0,
	JSON_reserved_mb			decimal(38,2) default 0,

	NCI_hash_used_mb			decimal(38,2) default 0,
	NCI_hash_reserved_mb		decimal(38,2) default 0,

	sum_used_mb					decimal(38,2) default 0,
	sum_reserved_mb				decimal(38,2) default 0,

	sum_reserved_free_mb		decimal(38,2) default 0		

	)


/* get tables list with schemas */
set @SQL = 'select
	[object_id],
	schema_name(schema_id),
	[name]
from ' + @DatabaseName + '.sys.tables
order by schema_name(schema_id), [name]'


insert into #Tables ([object_id], [schema_name], table_name)
exec (@SQL)

set @table_count = (select count(*) from #Tables)




/* get page counts by index type for each table */
drop table if exists #Sum_Index_Pages 

create table #Sum_Index_Pages (
	[object_id]							int,
	[type_desc]							nvarchar(60),
	count_of_indexes					int,
	sum_used_page_count					bigint,
	sum_reserved_page_count				bigint
	)


set @SQL = '
select
			t.[object_id],
			i.type_desc,
			count(*)							[count_of_indexes],
			sum(ps.used_page_count)				[sum_used_page_count],
			sum(ps.reserved_page_count)			[sum_reserved_page_count]
		from ' + @DatabaseName + '.sys.tables t
			join ' + @DatabaseName + '.sys.indexes i on 
				t.[object_id] = i.[object_id]
			join ' + @DatabaseName + '.sys.dm_db_partition_stats ps on
				t.[object_id] = ps.[object_id]
				and i.index_id = ps.index_id
		group by t.[object_id], i.type_desc'



insert into #Sum_Index_Pages ([object_id], [type_desc], count_of_indexes, sum_used_page_count, sum_reserved_page_count)
exec (@SQL)



/* calculate index sizes in megabytes */
update t
	set heap_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		heap_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'HEAP'


update t
	set CI_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		CI_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'CLUSTERED'


update t
	set NCI_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		NCI_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'NONCLUSTERED'


update t
	set CCI_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		CCI_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'CLUSTERED COLUMNSTORE'


update t
	set NCCI_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		NCCI_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'NONCLUSTERED COLUMNSTORE'



update t
	set XML_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		XML_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'XML'


update t
	set spatial_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		spatial_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'SPATIAL'


update t
	set NCI_hash_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		NCI_hash_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'NONCLUSTERED HASH'


update t
	set JSON_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		JSON_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from #Tables t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'JSON'



/* total values */
update #Tables
	set sum_used_mb = heap_used_mb + CI_used_mb + NCI_used_mb + CCI_used_mb + NCCI_used_mb + XML_used_mb + spatial_used_mb + JSON_used_mb + NCI_hash_used_mb,
		sum_reserved_mb = heap_reserved_mb + CI_reserved_mb + NCI_reserved_mb + CCI_reserved_mb + NCCI_reserved_mb + XML_reserved_mb + spatial_reserved_mb + JSON_reserved_mb + NCI_hash_reserved_mb


update #Tables
	set sum_reserved_free_mb = sum_reserved_mb - sum_used_mb




/* total database space usage */
drop table if exists #DatabaseSpaceUsage

create table #DatabaseSpaceUsage (
	total_data_file_mb					decimal(38,2),
	total_allocated_mb					decimal(38,2),
	total_used_space_pct				decimal(5,2)
	)


set @SQL = 'select
	sum(cast(total_page_count as decimal(38,2))) / 128.00						[total_size_MB],
	sum(cast(allocated_extent_page_count as decimal(38,2))) / 128.00			[used_MB]
from [' + @DatabaseName + '].sys.dm_db_file_space_usage'


insert into #DatabaseSpaceUsage (total_data_file_mb, total_allocated_mb)
exec (@SQL)


update #DatabaseSpaceUsage
	set total_used_space_pct = (total_allocated_mb / total_data_file_mb) * 100


select
	@total_data_file_mb = total_data_file_mb,
	@total_allocated_mb = total_allocated_mb,
	@total_used_space_pct = cast(total_used_space_pct as varchar) + ' %'
from #DatabaseSpaceUsage



/*************************************************** Show Data ************************************************/


/* simple */
if @ExpertMode = 0 begin

	select 
		@DatabaseName								[Database_Name],
		@table_count								[Table_Count],
		
		sum(CI_used_mb) + sum(heap_used_mb)			[Table_MB],
	
		sum(NCI_used_mb)							[NonClustered],
		sum(CCI_used_mb) + sum(NCCI_used_mb)		[Columnstore],

		sum(XML_used_mb) + sum(spatial_used_mb) + sum(JSON_used_mb) + sum(NCI_hash_used_mb)		[Other_IX],
	
		sum(sum_reserved_free_mb)					[Reserved],
		sum(sum_reserved_mb)						[Total_MB],

		@total_allocated_mb							[Allocated_MB],
		@total_data_file_mb							[Data_Files_MB],
		@total_used_space_pct						[Pct_Used]

	from #Tables


	select 
		[schema_name],
		table_name,
	
		case 
			when CI_used_mb > 0 then CI_used_mb
			when heap_used_mb > 0 then heap_used_mb
			when CI_used_mb = 0 and heap_used_mb = 0 then 0
		end											[Table_MB],
	
		NCI_used_mb									[NonClustered],
		CCI_used_mb + NCCI_used_mb					[Columnstore],

		XML_used_mb + spatial_used_mb + JSON_used_mb + NCI_hash_used_mb		[Other_IX],
	
		sum_reserved_free_mb						[Reserved],
		sum_reserved_mb								[Total_MB]

	from #Tables
	order by sum_reserved_mb desc

end





/* detailed */
if @ExpertMode = 1 begin

	select 
		@DatabaseName								[Database_Name],
		@table_count								[Table_Count],

		sum(heap_used_mb)							[Heap],
		sum(CI_used_mb)								[Clustered],
		sum(NCI_used_mb)							[NonClustered],
	
		sum(CCI_used_mb)							[CS_CI],
		sum(NCCI_used_mb)							[CS_NCI],

		sum(XML_used_mb)							[XML],
		sum(spatial_used_mb)						[Spatial],
		sum(JSON_used_mb)							[JSON],
		sum(NCI_hash_used_mb)						[NCI_Hash],

		sum(sum_reserved_free_mb)					[Reserved],
		sum(sum_reserved_mb)						[Total_MB],

		@total_allocated_mb							[Allocated_MB],
		@total_data_file_mb							[Data_Files_MB],
		@total_used_space_pct						[Pct_Used]


	from #Tables


	select 
		[schema_name],
		table_name,
	
		heap_used_mb						[Heap],
		CI_used_mb							[Clustered],
		NCI_used_mb							[NonClustered],
	
		CCI_used_mb							[CS_CI],
		NCCI_used_mb						[CS_NCI],

		XML_used_mb							[XML],
		spatial_used_mb						[Spatial],
		JSON_used_mb						[JSON],
		NCI_hash_used_mb					[NCI_Hash],

		sum_reserved_free_mb				[Reserved],
		sum_reserved_mb						[Total_MB]

	from #Tables
	order by sum_reserved_mb desc

end


end




/* test

exec DatabaseSpaceUsage
	@ExpertMode = 1


*/
