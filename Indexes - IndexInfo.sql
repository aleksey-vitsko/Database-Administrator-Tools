

create or alter procedure IndexInfo (@TableName varchar(100)) as begin


/************************************ INDEX INFO PROCEDURE **************************************

Author: Aleksey Vitsko
Created: August 2017

Version: 1.14
Description: For specified table, shows 1) index usage stats 2) defragmentation levels 3) missing index suggestions

-- Example: exec IndexInfo 'BoxInfo'

History


2019-02-18
Fixed bug that allowed to show missing index suggestions for tables with same object_id from other databases

2018-07-05
Fixed error that showed up when HEAP table name is supplied

2018-03-22
Added "index_columns" and "included_columns" into output result set

2017-08-15
Created procedure


*************************************************************************************************/

declare 
	--@TableName varchar(100) = 'BoxInfo', 
	@ObjectID bigint


select @ObjectID = [object_id] 
from sys.objects 
where [name] = @TableName


if object_id('TempDB..#IndexUsageStats') is not null begin drop table #IndexUsageStats end

create table #IndexUsageStats (
	[name]				varchar(200),

	[index_columns]		varchar(1000) default '',
	[included_columns]	varchar(1000) default '',

	[index_ID]			smallint primary key,
	[type_desc]			varchar(20),
	
	is_Unique			bit,
	is_primary_key		bit,
	
	user_seeks			int,
	user_scans			int,
	user_lookups		int,
	
	updates				int,
	Total_Usage			int
	)				


-- index usage stats
insert into #IndexUsageStats ([name], index_id, [type_desc], is_unique, is_primary_key, user_seeks, user_scans, user_lookups, updates, Total_Usage)
select 
	i.name,
	i.index_id, 
	i.type_desc,
	i.is_unique,
	i.is_primary_key,
	user_seeks,
	user_scans,
	user_lookups,
	user_updates							,
	user_seeks + user_scans + user_lookups	[TotalUsage]
from sys.indexes i
	join sys.dm_db_index_usage_stats indexstats on
		i.[object_id] = indexstats.[object_id]
		and i.[index_id] = indexstats.[index_id]
		and indexstats.database_id = db_id()
where	i.[object_id] = @ObjectID
order by [TotalUsage]



if object_id('TempDB..#IndexColumnsDetails') is not null begin drop table #IndexColumnsDetails end

create table #IndexColumnsDetails (
	[object_id]					int,
	[index_name]				varchar(200),
	[index_id]					smallint,
	[index_column_id]			smallint,
	[column_id]					int,
	key_ordinal					tinyint,
	is_included_column			bit,
	[column_name]				varchar(200))


insert into #IndexColumnsDetails ([object_id], [index_name], [index_id], [index_column_id], [column_id], key_ordinal, is_included_column, [column_name])
select i.object_id, i.[name], ic.index_id, index_column_id, ic.column_id, key_ordinal, is_included_column, c.[name]
from sys.indexes i
	join sys.index_columns ic on
		i.object_id = ic.object_id
		and i.index_id = ic.index_id
	join sys.columns c on
		i.object_id = c.object_id
		and ic.column_id = c.column_id
where i.object_id = @ObjectID
order by i.[name], index_column_id



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

	-- column name to #IndexUsageStats table
	if @is_included_column = 0 begin
		update #IndexUsageStats
			set [index_columns] = [index_columns] + @column_name + ', '
		where Index_ID = @index_id
	end

	-- column name to #IndexUsageStats table
	if @is_included_column = 1 begin
		update #IndexUsageStats
			set included_columns = included_columns + @column_name + ', '
		where Index_ID = @index_id
	end

	fetch next from IndexColumns into @index_id, @index_column_id, @is_included_column, @column_name

end		-- cursor cycle end

close IndexColumns
deallocate IndexColumns


-- trim right commas
update #IndexUsageStats
	set index_columns = left(index_columns,len(index_columns) -1 ) 
where len(index_columns) > 0

update #IndexUsageStats
	set included_columns = left(included_columns,len(included_columns) -1 ) 
where len(included_columns) > 0


select 
	[name],
	index_ID,
	[type_desc],
	is_Unique,
	is_primary_key,
	user_seeks,
	user_scans,
	user_lookups,
	updates,
	Total_Usage,
	[index_columns],
	included_columns
from #IndexUsageStats
order by Total_Usage



-- index physical stats
select 
	i.name,
	--physicalstats.index_type_desc,
	index_depth,
	index_level,
	page_count / 128	[size_MB],
	page_count,
	fragment_count,
	avg_fragmentation_in_percent,
	avg_fragment_size_in_pages
	
from sys.indexes i
	join sys.dm_db_index_physical_stats (db_id(),@ObjectID,NULL,NULL,NULL) physicalstats on
		physicalstats.database_id = db_id()
		and i.[object_id] = physicalstats.[object_id]
		and i.[index_id] = physicalstats.[index_id]
order by avg_fragmentation_in_percent





-- suggested indexes
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
where	mid.[object_id] = @ObjectID
		and mid.database_id = db_id()
order by [avg_estimated_impact]






/*


select [object_id] 
from sys.objects 
where [name] = 'BoxInfo'


select * from sys.indexes
where object_id = 2140443295


select * from sys.index_columns
where object_id = 2140443295


select * from sys.index_columns
where	object_id = 2140443295
		
select * from sys.columns
where	object_id = 2140443295



select i.object_id, i.[name], ic.index_id, index_column_id, ic.column_id, key_ordinal, is_included_column, c.[name]
from sys.indexes i
	join sys.index_columns ic on
		i.object_id = ic.object_id
		and i.index_id = ic.index_id
	join sys.columns c on
		i.object_id = c.object_id
		and ic.column_id = c.column_id
where i.object_id = 2140443295
order by i.[name], index_column_id


select * from sys.dm_db_index_usage_stats
where object_id = 2140443295



select * from sys.dm_db_missing_index_details
where object_id = 2140443295


select * from sys.dm_db_missing_index_groups
where index_handle in (select index_handle from sys.dm_db_missing_index_details where object_id = 2140443295)


select * from sys.dm_db_missing_index_group_stats 
where group_handle in (select index_group_handle from sys.dm_db_missing_index_groups
where index_handle in (select index_handle from sys.dm_db_missing_index_details where object_id = 2140443295))

*/


end