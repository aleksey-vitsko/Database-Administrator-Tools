

create or alter procedure DatabaseSpaceUsage (
	@DatabaseName					nvarchar(128)	= '',
	@ExpertMode						smallint = 0,
	
	@LogToTable						varchar(256) = ''
	)
with execute as owner
as begin



/****************************************************************** DATABASE SPACE USAGE PROCEDURE **************************************************************

Author: Aleksey Vitsko


Version: 2.4

Description: 

For a given database, shows how much space is used by:

- data (heap, clustered)
- indexes (NCI, CCI, NCCI, XML, JSON, Spatial, NCI Hash)
- reserved space

On database and table/view levels.
All numbers are in megabytes, with two digits precision.


History:

2026-11-14 -> Aleksey Vitsko - added logging functionality (@LogToTable)
2026-11-13 -> Aleksey Vitsko - added query store size info
2026-11-12 -> Aleksey Vitsko - added support for indexed views
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

	@query_store_mb				int,

	@table_count				int,
	@indexed_view_count			int


/* main temp table holding list of tables */
drop table if exists ##Tables_and_Views 

create table ##Tables_and_Views (
	ID							int identity primary key,
	
	[object_id]					bigint,
	[schema_name]				nvarchar(128),

	table_name					nvarchar(128),
	indexed_view_name			nvarchar(128),

	[type]						varchar(10),

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
	[name],
	''table''
from ' + @DatabaseName + '.sys.tables
order by schema_name(schema_id), [name]'


insert into ##Tables_and_Views ([object_id], [schema_name], table_name, [type])
exec (@SQL)

set @table_count = (select count(*) from ##Tables_and_Views where [type] = 'table')




/* get indexed views list with schemas */
set @SQL = 'select
	v.[object_id],
	schema_name(v.schema_id),
	v.[name],
	''view''
from ' + @DatabaseName + '.sys.views v
	join ' + @DatabaseName + '.sys.indexes i on
		v.object_id = i.object_id
group by v.object_id, schema_name(v.schema_id), v.[name]
order by schema_name(v.schema_id), v.[name]'


insert into ##Tables_and_Views ([object_id], [schema_name], indexed_view_name, [type])
exec (@SQL)

set @indexed_view_count = (select count(*) from ##Tables_and_Views where [type] = 'view')





/* get page counts by index type for each table or indexed view */
drop table if exists #Sum_Index_Pages 

create table #Sum_Index_Pages (
	[object_id]							int,
	[type_desc]							nvarchar(60),
	count_of_indexes					int,
	sum_used_page_count					bigint,
	sum_reserved_page_count				bigint
	)


/* for tables */
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



/* for views */
set @SQL = '
select
			v.[object_id],
			i.type_desc,
			count(*)							[count_of_indexes],
			sum(ps.used_page_count)				[sum_used_page_count],
			sum(ps.reserved_page_count)			[sum_reserved_page_count]
		from ' + @DatabaseName + '.sys.views v
			join ' + @DatabaseName + '.sys.indexes i on 
				v.[object_id] = i.[object_id]
			join ' + @DatabaseName + '.sys.dm_db_partition_stats ps on
				v.[object_id] = ps.[object_id]
				and i.index_id = ps.index_id
		group by v.[object_id], i.type_desc'


insert into #Sum_Index_Pages ([object_id], [type_desc], count_of_indexes, sum_used_page_count, sum_reserved_page_count)
exec (@SQL)





/* calculate index sizes in megabytes */
update t
	set heap_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		heap_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'HEAP'


update t
	set CI_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		CI_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'CLUSTERED'


update t
	set NCI_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		NCI_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'NONCLUSTERED'


update t
	set CCI_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		CCI_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'CLUSTERED COLUMNSTORE'


update t
	set NCCI_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		NCCI_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'NONCLUSTERED COLUMNSTORE'



update t
	set XML_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		XML_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'XML'


update t
	set spatial_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		spatial_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'SPATIAL'


update t
	set NCI_hash_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		NCI_hash_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'NONCLUSTERED HASH'


update t
	set JSON_used_mb = cast([sum_used_page_count] as decimal(38,2)) / 128,
		JSON_reserved_mb = cast([sum_reserved_page_count] as decimal(38,2)) / 128
from ##Tables_and_Views t
	join #Sum_Index_Pages s on
		t.[object_id] = s.[object_id]
		and s.[type_desc] = 'JSON'



/* total values */
update ##Tables_and_Views
	set sum_used_mb = heap_used_mb + CI_used_mb + NCI_used_mb + CCI_used_mb + NCCI_used_mb + XML_used_mb + spatial_used_mb + JSON_used_mb + NCI_hash_used_mb,
		sum_reserved_mb = heap_reserved_mb + CI_reserved_mb + NCI_reserved_mb + CCI_reserved_mb + NCCI_reserved_mb + XML_reserved_mb + spatial_reserved_mb + JSON_reserved_mb + NCI_hash_reserved_mb


update ##Tables_and_Views
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



/* query store size */
drop table if exists #query_store_mb

create table #query_store_mb (	
	query_store_mb				int
	)

set @SQL = 'select current_storage_size_mb from ' + @DatabaseName + '.sys.database_query_store_options'

insert into #query_store_mb
exec (@SQL)

set @query_store_mb = (select query_store_mb from #query_store_mb)




/* log to table */
if @LogToTable <> '' begin

	set @SQL = 'drop table if exists #Count

	create table #Count (Cnt int)

	insert into #Count (cnt)
	select count(*) from ' + @LogToTable

	/* check if table exists */
	begin try
	
		exec (@SQL)
	
	end try

	/* if not, create it */
	begin catch
	
		set @SQL = 'create table ' + @LogToTable + ' (
			ID						int identity primary key,
			Date_Time				datetime default getdate(),
			
			Database_Name			varchar(128),
			Table_Count				int,
			Indexed_Views			int,
		
			Table_MB				int,
			[NonClustered]			int,
			[ColumnStore]			int,
			Other_IX				int,
			Reserved				int,
			QueryStore				int,
			Sum_MB					int,
			Allocated_MB			int,
			Data_Files_MB			int,
			Pct_Used				varchar(10),

			Allocated_Delta_MB		int
			)' 

		exec(@SQL)

	end catch
	
	set @SQL = 'insert into ' + @LogToTable + ' (Database_Name, Table_Count, Indexed_Views, Table_MB, [NonClustered], [ColumnStore], Other_IX, Reserved, QueryStore, Sum_MB, Allocated_MB, Data_Files_MB, Pct_Used)
	select 
		''' + @DatabaseName + ''',
		' + cast(@table_count as varchar) + ',
		' + cast(@indexed_view_count as varchar) + ',
		
		sum(CI_used_mb) + sum(heap_used_mb)			[Table_MB],
	
		sum(NCI_used_mb)							[NonClustered],
		sum(CCI_used_mb) + sum(NCCI_used_mb)		[Columnstore],

		sum(XML_used_mb) + sum(spatial_used_mb) + sum(JSON_used_mb) + sum(NCI_hash_used_mb)		[Other_IX],
	
		sum(sum_reserved_free_mb)					[Reserved],
		
		' + cast(@query_store_mb as varchar) + '	[QueryStore],
		sum(sum_reserved_mb) + ' + cast(@query_store_mb as varchar) + '		[Sum_MB],
		
		' + cast(@total_allocated_mb as varchar) + '							[Allocated_MB],
		' + cast(@total_data_file_mb as varchar)	+ '						[Data_Files_MB],
		''' + cast(@total_used_space_pct as varchar) + '''						[Pct_Used]

	from ##Tables_and_Views'

	exec (@SQL)
	

	/* calculate allocated_delta_mb */
	set @SQL = 'declare 
			@ID						int,
			@ID_prev				int,
			@Allocated_MB_prev		int
	
		set @ID = (select max(ID) from ' +  @LogToTable + ')

		set @ID_prev = (select max(ID) from ' +  @LogToTable + ' where Database_Name = ''' + @DatabaseName + ''' and ID < @ID)

		if @ID_prev is NULL begin set @ID_prev = 0 end

		set @Allocated_MB_prev = (select Allocated_MB from ' +  @LogToTable + ' where ID = @ID_prev)

		update top(1) ' +  @LogToTable + '
			set Allocated_Delta_MB = Allocated_MB - @Allocated_MB_prev
		where ID = @ID

	'

	exec (@SQL)

end




/*************************************************** Show Data ************************************************/


/* simple */
if @ExpertMode = 0 begin

	select 
		@DatabaseName								[Database_Name],
		@table_count								[Table_Count],
		@indexed_view_count							[Indexed_Views],
		
		sum(CI_used_mb) + sum(heap_used_mb)			[Table_MB],
	
		sum(NCI_used_mb)							[NonClustered],
		sum(CCI_used_mb) + sum(NCCI_used_mb)		[Columnstore],

		sum(XML_used_mb) + sum(spatial_used_mb) + sum(JSON_used_mb) + sum(NCI_hash_used_mb)		[Other_IX],
	
		sum(sum_reserved_free_mb)					[Reserved],
		
		@query_store_mb								[QueryStore],
		sum(sum_reserved_mb) + @query_store_mb		[Sum_MB],
		
		@total_allocated_mb							[Allocated_MB],
		@total_data_file_mb							[Data_Files_MB],
		@total_used_space_pct						[Pct_Used]

	from ##Tables_and_Views


	select 
		[schema_name],
		coalesce(table_name,indexed_view_name)		[table_or_view],
		
		case 
			when [type] = 'table' then 'T'
			when [type] = 'view' then 'V'
		end	[Type],

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

	from ##Tables_and_Views
	order by sum_reserved_mb desc

end





/* detailed */
if @ExpertMode = 1 begin

	select 
		@DatabaseName								[Database_Name],
		@table_count								[Table_Count],
		@indexed_view_count							[Indexed_Views],

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
		
		@query_store_mb								[QueryStore],
		sum(sum_reserved_mb) + 	@query_store_mb		[Sum_MB],
		@total_allocated_mb							[Allocated_MB],
		@total_data_file_mb							[Data_Files_MB],
		@total_used_space_pct						[Pct_Used]


	from ##Tables_and_Views


	select 
		[schema_name],
		coalesce(table_name,indexed_view_name)		[table_or_view],
	
		case 
			when [type] = 'table' then 'T'
			when [type] = 'view' then 'V'
		end	[Type],

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

	from ##Tables_and_Views
	order by sum_reserved_mb desc

end


end




/* test

exec DatabaseSpaceUsage
	@ExpertMode = 1


*/
