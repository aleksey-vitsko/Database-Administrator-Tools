

create or alter procedure IndexInfo (
	@TableName					varchar(100),					/* mandatory, specify table name for which you want to see index information */
	@SchemaName					varchar(128) = 'dbo',			/* by default, dbo schema is assumed */
	@DatabaseName				varchar(128) = '',				/* if empty space, db_name() of current database will be used */
	
	@IndexName					varchar(128) = '',				/* optional, specify specific index's name */
	
	@PhysicalStats				int = 1							/* set this to 0 when calling SP, if querying physical stats is too slow */
	) 
	
as begin


/******************************************************** INDEX INFO PROCEDURE ********************************************************

Author: Aleksey Vitsko

Version: 2.00


Description: For specified table, shows:

1) general index information
2) index usage and operational stats 
3) index physical stats
4) missing index suggestions


History

2025-07-14 -> Aleksey Vitsko - major rewrite of stored procedure (version 2.0 released)
2019-02-18 -> Aleksey Vitsko - fixed bug that allowed to show missing index suggestions for tables with same object_id from other databases
2018-07-05 -> Aleksey Vitsko - fixed error that showed up when HEAP table name is supplied
2018-03-22 -> Aleksey Vitsko - added "index_columns" and "included_columns" into output result set
2017-08-15 -> Aleksey Vitsko - created procedure (1st version)


Tested on:

- SQL Server 2016 (SP2), 2017 (CU31), 2019 (RTM), 2022 (RTM)
- Azure SQL Managed Instance (SQL 2022 update policy)
- Azure SQL Database


***************************************************************************************************************************************/

set nocount on

/* parameters */
declare 
	@Query			varchar(max),
	@db_id			int,
	@object_id		int
	


/********************************************* Pre-checks and Validations ***************************************************************/

/* if db name is empty, set to current selected database */
	if @DatabaseName = '' begin 
		set @DatabaseName = db_name()
	end


/* check if specified database name exists at sys.databases */
if not exists (select * from sys.databases where [name] = @DatabaseName) begin
		print 'Specified database [' + @DatabaseName + '] does not exist!'
		print 'Please specify database that exists at sys.databases.'
		print 'Exiting...'
		return
	end


	
/* check if schema exists */
declare @t table (
	Number int
	)

if @SchemaName <> 'dbo' begin
	
	set @Query = 'select count(*) from ' + @DatabaseName + '.sys.schemas where name = ''' + @SchemaName + '''' 

	insert into @t
	exec(@Query)
	
	if (select top(1) Number from @t) = 0 begin
	print 'Specified schema [' + @SchemaName + '] does not exist!'
	print 'Please specify schema that exists at sys.schemas at selected database.'
	print 'Exiting...'
	return
end	

end


/* check if table exists */
set @Query = 'select count(*) from ' + @DatabaseName + '.sys.tables t
	join ' + @DatabaseName + '.sys.schemas s on
		t.[schema_id] = s.[schema_id] 
		and s.[name] = ''' + @SchemaName + '''' + '
where t.name = ''' + @TableName + '''' 


delete from @t

insert into @t
exec(@Query)

if (select top(1) Number from @t) = 0 begin
	print 'Specified table [' + @TableName + '] does not exist at schema [' + @SchemaName + '] !'
	print 'Please specify table that exists in specified schema in selected database.'
	print 'Exiting...'
	return
end	






/********************************************* Temp Tables, Etc. ***************************************************************/


drop table if exists #TableIndexes

create table #TableIndexes (
	ID							int identity primary key,
	
	[database_name]				varchar(128),
	[schema_name]				varchar(128),
	
	table_name					varchar(128),
	[object_id]					int,

	index_name					varchar(128),
	index_id					int,
	[type_desc]					varchar(128),

	[index_columns]				varchar(2000) default '',
	included_columns			varchar(2000) default ''
	)


set @Query = 'select i.[object_id], i.[name], index_id, i.[type_desc]
from ' + @DatabaseName + '.sys.indexes i
	
	join ' + @DatabaseName + '.sys.tables t on
		i.[object_id] = t.[object_id]
		and t.name = ''' + @TableName + '''' + '

	join ' + @DatabaseName + '.sys.schemas s on
		t.[schema_id] = s.[schema_id]
		and s.name = ''' + @SchemaName + '''' 


insert into #TableIndexes ([object_id], index_name, index_id, [type_desc])
exec (@Query)


update #TableIndexes
	set [database_name] = @DatabaseName,
		[schema_name] = @SchemaName,
		[table_name] = @TableName




/* if user specified @IndexName parameter, show only information related to that particular index */
if @IndexName <> '' begin 

	if not exists (select * from #TableIndexes where index_name = @IndexName) begin
		print 'Specified index name [' + @IndexName + '] was not found in table [' + @TableName + ']!'
		print 'Please specify index name that exists in table [' + @TableName + '].'
		print 'Exiting...'
		return
	end

	delete from #TableIndexes 
	where index_name <> @IndexName
end




/* get database id and object id */ 
set @db_id = (select [database_id] 
				from sys.databases 
				where [name] = @DatabaseName)

set @object_id = (select top 1 [object_id] 
					from #TableIndexes)



/* determine version */
declare @Version varchar(10)

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





/************************************************** Collecting Information ***************************************************************/


/* comma-separated list of indexes' columns */

drop table if exists #IndexColumnsDetails

create table #IndexColumnsDetails (
	[object_id]					int,
	[index_name]				varchar(200),
	[index_id]					smallint,
	[index_column_id]			smallint,
	[column_id]					int,
	key_ordinal					tinyint,
	is_included_column			bit,
	[column_name]				varchar(200))



set @Query = 'select i.object_id, i.[name], ic.index_id, index_column_id, ic.column_id, key_ordinal, is_included_column, c.[name]
from [' + @DatabaseName + '].sys.indexes i
	join [' + @DatabaseName + '].sys.index_columns ic on
		i.object_id = ic.object_id
		and i.index_id = ic.index_id
	join [' + @DatabaseName + '].sys.columns c on
		i.object_id = c.object_id
		and ic.column_id = c.column_id
where i.object_id = ' + cast(@object_id as varchar) + '
order by i.[name], index_column_id'



insert into #IndexColumnsDetails ([object_id], [index_name], [index_id], [index_column_id], [column_id], key_ordinal, is_included_column, [column_name])
exec (@Query)



declare @index_id smallint, @index_column_id smallint, @is_included_column bit, @column_name nvarchar(200)

declare IndexColumns cursor local fast_forward for
select
	index_id,
	index_column_id,
	is_included_column,
	column_name 
from #IndexColumnsDetails
order by index_id, index_column_id

open IndexColumns
fetch next from IndexColumns into @index_id, @index_column_id, @is_included_column, @column_name

while @@FETCH_STATUS = 0 begin

	/* index column names to #TableIndexes table */
	if @is_included_column = 0 begin
		update #TableIndexes
			set [index_columns] = [index_columns] + @column_name + ', '
		where Index_ID = @index_id
	end

	/* included column names to #TableIndexes table */
	if @is_included_column = 1 begin
		update #TableIndexes
			set included_columns = included_columns + @column_name + ', '
		where Index_ID = @index_id
	end

	fetch next from IndexColumns into @index_id, @index_column_id, @is_included_column, @column_name

end		/* cursor cycle end */

close IndexColumns
deallocate IndexColumns


/* trim right commas */
update #TableIndexes
	set [index_columns] = left([index_columns],len([index_columns]) -1 ) 
where len([index_columns]) > 0

update #TableIndexes
	set included_columns = left(included_columns,len(included_columns) -1 ) 
where len(included_columns) > 0





/* show general index information */

if @Version in ('2019','2022','2025','SQL Azure') or cast(@Version as int) > 2025 begin 

	set @Query = 'select
		[table_name],
		[name],
		ti.index_id,
		ti.[type_desc],

		[index_columns],
		included_columns,

		is_primary_key,
	
		is_unique,
		is_unique_constraint,
	
		data_space_id,
		[ignore_dup_key],
		fill_factor,
		is_padded,
		is_disabled,
		is_ignored_in_optimization,
		is_hypothetical,
		[allow_row_locks],
		[allow_page_locks],
		has_filter,
		filter_definition,
		[compression_delay],
		suppress_dup_key_messages,
		auto_created,
		[optimize_for_sequential_key]

	from #TableIndexes ti
	
		join [' + @DatabaseName + '].sys.indexes i on
			ti.[object_id] = i.object_id
			and ti.index_id = i.index_id
		
	order by index_id' 

end


if @Version in ('2016','2017')  begin 

	set @Query = 'select
		[table_name],
		[name],
		ti.index_id,
		ti.[type_desc],

		[index_columns],
		included_columns,

		is_primary_key,
	
		is_unique,
		is_unique_constraint,
	
		data_space_id,
		[ignore_dup_key],
		fill_factor,
		is_padded,
		is_disabled,
		is_hypothetical,
		[allow_row_locks],
		[allow_page_locks],
		has_filter,
		filter_definition,
		[compression_delay]
	
	from #TableIndexes ti
	
		join [' + @DatabaseName + '].sys.indexes i on
			ti.[object_id] = i.object_id
			and ti.index_id = i.index_id
		
	order by index_id' 

end


select 'General Info:'

exec (@Query)





/* show index usage and operational stats */

select 'Usage and Operational Stats:'

if @Version in ('2019','2022','2025','SQL Azure') or cast(@Version as int) > 2025 begin 

	select
		table_name,
		index_name,
		/*[type_desc],*/

		isnull(leaf_insert_count,0) +	isnull(nonleaf_insert_count,0)						[Inserts],				-- sum of Leaf and Nonleaf inserts
		isnull(leaf_delete_count,0) +	 isnull(iop.nonleaf_delete_count,0)					[Deletes],				-- sum of Leaf and Nonleaf deletes
		isnull(leaf_update_count,0) +	 isnull(iop.nonleaf_update_count,0)					[Updates],				-- sum of Leaf and Nonleaf updates
		isnull(leaf_ghost_count,0)															[Ghosts],				-- sum of Leaf and Nonleaf ghosted records
      
		isnull(range_scan_count,0)															[Range_Scans],
		isnull(singleton_lookup_count,0)													[Singleton_Lookups],

		isnull(ius.user_seeks,0)															[User_Seeks],
		isnull(ius.user_scans,0)															[User_Scans],
		isnull(ius.user_lookups,0)															[User_Lookups],
		isnull(ius.user_updates,0)															[User_Updates],

		isnull(ius.system_seeks,0)															[System_Seeks],
		isnull(ius.system_scans,0)															[System_Scans],
		isnull(ius.system_lookups,0)														[System_Lookups],
		isnull(ius.system_updates,0)														[System_Updates],


		isnull(row_lock_count,0)															[RowLocks],
		isnull(page_lock_count,0)															[PageLocks],

		isnull(page_latch_wait_count,0)														[Latch_Waits],
		isnull(page_io_latch_wait_count,0)													[IO_Latch_Waits],

		isnull(tree_page_latch_wait_count,0)												[Tree_Latch_Waits],
		isnull(tree_page_io_latch_wait_count,0)												[Tree_IO_Latch_Waits],

		isnull(forwarded_fetch_count,0)														[Forwarded_Fetches],
		isnull(lob_fetch_in_pages,0)														[LOB_Fetches],
		isnull(lob_orphan_create_count,0)													[LOB_Orphan_Creates],
		isnull(lob_orphan_insert_count,0)													[LOB_Orphan_Inserts],
			
		isnull(column_value_push_off_row_count,0)											[ColVal_Off_Row],
		isnull(column_value_pull_in_row_count,0)											[ColVal_In_Row],
		
		isnull(row_overflow_fetch_in_pages,0)												[Row_Overflow_Fetches],
	
		isnull(index_lock_promotion_attempt_count,0)										[Escalation_Attempts],
		isnull(index_lock_promotion_count,0)												[Lock_Escalations],

		isnull(page_compression_attempt_count,0)											[Page_Compression_Attempts],
		isnull(page_compression_success_count,0)											[Page_Compression_Success],

		isnull(version_generated_inrow,0)													[Version_Generated_In_Row],
		isnull(version_generated_offrow,0)													[Version_Generated_Off_Row],

		isnull(ghost_version_inrow,0)														[Ghost_Version_In_Row],
		isnull(ghost_version_offrow,0)														[Ghost_Version_Off_Row],

		isnull(insert_over_ghost_version_inrow,0)											[Insert_Over_Ghost_In_Row],
		isnull(insert_over_ghost_version_offrow,0)											[Insert_Over_Ghost_Off_Row],
		
		isnull(leaf_insert_count,0) +	
		isnull(nonleaf_insert_count,0) + 
		isnull(leaf_delete_count,0) +	 
		isnull(iop.nonleaf_delete_count,0) +
		isnull(leaf_update_count,0) +	 
		isnull(iop.nonleaf_update_count,0) +
		isnull(leaf_ghost_count,0)	+
		isnull(range_scan_count,0) +
		isnull(singleton_lookup_count,0) +
		isnull(ius.user_seeks,0) +
		isnull(ius.user_scans,0) +
		isnull(ius.user_lookups,0) +
		isnull(ius.user_updates,0) +
		isnull(ius.system_seeks,0) +
		isnull(ius.system_scans,0) +
		isnull(ius.system_lookups,0) +
		isnull(ius.system_updates,0) +
		isnull(row_lock_count,0) +
		isnull(page_lock_count,0) +
		isnull(page_latch_wait_count,0) +
		isnull(page_io_latch_wait_count,0) +
		isnull(tree_page_latch_wait_count,0) +
		isnull(tree_page_io_latch_wait_count,0) +
		isnull(forwarded_fetch_count,0) +
		isnull(lob_fetch_in_pages,0) +
		isnull(lob_orphan_create_count,0) +
		isnull(lob_orphan_insert_count,0) +
		isnull(column_value_push_off_row_count,0) +
		isnull(column_value_pull_in_row_count,0) +
		isnull(row_overflow_fetch_in_pages,0) +
		isnull(index_lock_promotion_attempt_count,0) +
		isnull(index_lock_promotion_count,0) +
		isnull(page_compression_attempt_count,0) +
		isnull(page_compression_success_count,0) +
		isnull(version_generated_inrow,0) +
		isnull(version_generated_offrow,0)	 +
		isnull(ghost_version_inrow,0) +
		isnull(ghost_version_offrow,0) +
		isnull(insert_over_ghost_version_inrow,0) +
		isnull(insert_over_ghost_version_offrow,0)				[Sum_Usage]

	from #TableIndexes ti
		
		left join sys.dm_db_index_usage_stats ius on 
			ius.[database_id] = @db_id
			and ti.[object_id] = ius.[object_id]
			and ti.[index_id] = ius.[index_id]
		
		left join sys.dm_db_index_operational_stats (@db_id,@object_id,NULL,NULL) iop on
			iop.[database_id] = @db_id
			and ti.[object_id] = iop.[object_id]
			and ti.[index_id] = iop.[index_id]

	order by [Sum_Usage] desc

end


/* SQL Server 2016-2017 */

if @Version in ('2016','2017') begin

	select
		table_name,
		index_name,
		[type_desc],

		isnull(leaf_insert_count,0) +	isnull(nonleaf_insert_count,0)						[Inserts],				-- sum of Leaf and Nonleaf inserts
		isnull(leaf_delete_count,0) +	 isnull(iop.nonleaf_delete_count,0)					[Deletes],				-- sum of Leaf and Nonleaf deletes
		isnull(leaf_update_count,0) +	 isnull(iop.nonleaf_update_count,0)					[Updates],				-- sum of Leaf and Nonleaf updates
		isnull(leaf_ghost_count,0)															[Ghosts],				-- sum of Leaf and Nonleaf ghosted records
      
		isnull(range_scan_count,0)															[Range_Scans],
		isnull(singleton_lookup_count,0)													[Singleton_Lookups],

		isnull(ius.user_seeks,0)															[User_Seeks],
		isnull(ius.user_scans,0)															[User_Scans],
		isnull(ius.user_lookups,0)															[User_Lookups],
		isnull(ius.user_updates,0)															[User_Updates],

		isnull(ius.system_seeks,0)															[System_Seeks],
		isnull(ius.system_scans,0)															[System_Scans],
		isnull(ius.system_lookups,0)														[System_Lookups],
		isnull(ius.system_updates,0)														[System_Updates],


		isnull(row_lock_count,0)															[RowLocks],
		isnull(page_lock_count,0)															[PageLocks],

		isnull(page_latch_wait_count,0)														[Latch_Waits],
		isnull(page_io_latch_wait_count,0)													[IO_Latch_Waits],

		isnull(tree_page_latch_wait_count,0)												[Tree_Latch_Waits],
		isnull(tree_page_io_latch_wait_count,0)												[Tree_IO_Latch_Waits],

		isnull(forwarded_fetch_count,0)														[Forwarded_Fetches],
		isnull(lob_fetch_in_pages,0)														[LOB_Fetches],
		isnull(lob_orphan_create_count,0)													[LOB_Orphan_Creates],
		isnull(lob_orphan_insert_count,0)													[LOB_Orphan_Inserts],
			
		isnull(column_value_push_off_row_count,0)											[ColVal_Off_Row],
		isnull(column_value_pull_in_row_count,0)											[ColVal_In_Row],
		
		isnull(row_overflow_fetch_in_pages,0)												[Row_Overflow_Fetches],
	
		isnull(index_lock_promotion_attempt_count,0)										[Escalation_Attempts],
		isnull(index_lock_promotion_count,0)												[Lock_Escalations],

		isnull(page_compression_attempt_count,0)											[Page_Compression_Attempts],
		isnull(page_compression_success_count,0)											[Page_Compression_Success],

		isnull(leaf_insert_count,0) +	
		isnull(nonleaf_insert_count,0) + 
		isnull(leaf_delete_count,0) +	 
		isnull(iop.nonleaf_delete_count,0) +
		isnull(leaf_update_count,0) +	 
		isnull(iop.nonleaf_update_count,0) +
		isnull(leaf_ghost_count,0)	+
		isnull(range_scan_count,0) +
		isnull(singleton_lookup_count,0) +
		isnull(ius.user_seeks,0) +
		isnull(ius.user_scans,0) +
		isnull(ius.user_lookups,0) +
		isnull(ius.user_updates,0) +
		isnull(ius.system_seeks,0) +
		isnull(ius.system_scans,0) +
		isnull(ius.system_lookups,0) +
		isnull(ius.system_updates,0) +
		isnull(row_lock_count,0) +
		isnull(page_lock_count,0) +
		isnull(page_latch_wait_count,0) +
		isnull(page_io_latch_wait_count,0) +
		isnull(tree_page_latch_wait_count,0) +
		isnull(tree_page_io_latch_wait_count,0) +
		isnull(forwarded_fetch_count,0) +
		isnull(lob_fetch_in_pages,0) +
		isnull(lob_orphan_create_count,0) +
		isnull(lob_orphan_insert_count,0) +
		isnull(column_value_push_off_row_count,0) +
		isnull(column_value_pull_in_row_count,0) +
		isnull(row_overflow_fetch_in_pages,0) +
		isnull(index_lock_promotion_attempt_count,0) +
		isnull(index_lock_promotion_count,0) +
		isnull(page_compression_attempt_count,0) +
		isnull(page_compression_success_count,0) 				[Sum_Usage]


	from #TableIndexes ti
		
		left join sys.dm_db_index_usage_stats ius on 
			ius.[database_id] = @db_id
			and ti.[object_id] = ius.[object_id]
			and ti.[index_id] = ius.[index_id]
		
		left join sys.dm_db_index_operational_stats (@db_id,@object_id,NULL,NULL) iop on
			iop.[database_id] = @db_id
			and ti.[object_id] = iop.[object_id]
			and ti.[index_id] = iop.[index_id]

	order by [Sum_Usage] desc

end




/* index physical stats */

if @PhysicalStats = 1 begin

select 'Physical stats:'

set @Query = '
	select 
		table_name,
		index_name,
		--ti.index_id,
	
		alloc_unit_type_desc,
		data_compression_desc							[data_compression],

		page_count / 128								[size_MB],
		round(avg_fragmentation_in_percent,2)			[fragmentation_pct],

		index_depth,
		index_level,

		page_count,
		fragment_count,
		page_count * 8									[size_kb],

		round(avg_fragment_size_in_pages,2)				[avg_fragment_size_in_pages]
		
		
	from #TableIndexes ti

		left join sys.dm_db_index_physical_stats (' + cast(@db_id as varchar) + ',' + cast(@object_id as varchar) + ',NULL,NULL,NULL) ips on
			ips.database_id = ' + cast(@db_id as varchar) + '
			and ti.[object_id] = ips.[object_id]
			and ti.[index_id] = ips.[index_id]

		left join ' + @DatabaseName + '.sys.partitions p on
			ti.[object_id] = p.[object_id]
			and ti.[index_id] = p.[index_id]
			and ips.partition_number = p.partition_number

	order by [size_kb] desc'

	exec (@Query)

end




/* suggested indexes */

select 'Missing Index Recommendations:'

select 
	equality_columns,
	inequality_columns,
	included_columns,
	unique_compiles,
	user_seeks,
	user_scans,
	avg_total_user_cost,
	avg_user_impact,
	avg_user_impact * (user_seeks + user_scans)		[avg_estimated_impact]

from sys.dm_db_missing_index_details mid
	
	join sys.dm_db_missing_index_groups mig on
		mid.index_handle = mig.index_handle
	
	join sys.dm_db_missing_index_group_stats migs on
		mig.index_group_handle = migs.group_handle

where	mid.[object_id] = @object_id
		and mid.database_id = @db_id

order by [avg_estimated_impact]




print @DatabaseName
print @SchemaName
print @TableName
print @IndexName


end