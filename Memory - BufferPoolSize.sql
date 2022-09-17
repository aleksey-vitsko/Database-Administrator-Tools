

create or alter procedure BufferPoolSize (
	@DetailType			varchar(50) = ''		
) 

as begin


/************************************************************ BUFFER POOL SIZE PROCEDURE ***********************************************************

Author: Aleksey Vitsko

Version: 1.02

Description: shows buffer pool size information (how much of database 8K-pages is cached in memory)

--------------------------------------------------------------------------

Accepts @DetailType parameter (output depends on supplied value):
''								- default value, shows summary + database level information
'summary'						- summary information
'database','databases'			- show database-level information
'clean" or "dirty'				- show clean and dirty buffer details
'page type' or 'page types'		- show data / index / other page details

--------------------------------------------------------------------------

History:

2022-09-17 --> Aleksey Vitsko - output [Buffer_Pool_Size_GB] as decimal instead of integer
2022-09-17 --> Aleksey Vitsko - for database-level information, sort by [Buffer_Pool_Size_MB] descending
2021-01-19 --> Aleksey Vitsko - fixed INT arithmetic overflow issue with row_count
2019-08-10 --> Aleksey Vitsko - created procedure

*****************************************************************************************************************************************************/



-- @DetailType value validation
if @DetailType not in ('','summary','database','databases','clean','dirty','page type','page types') begin

	print 'Incorrect value supplied for @DetailType
	
@DetailType allowed values:
	
""								- summary + database-level information (default)
"summary"						- shows summary information
"database" or "databases"		- show database-level information
"clean" or "dirty"				- show clean and dirty buffer details
"page type" or "page types"		- show data / index / other page details'

	return
end




-- summary
if @DetailType in ('','summary') begin

	declare @PageCount bigint, @RowCount bigint, @FreeSpaceMB bigint, @Pct_Free_Space decimal(5,2)

	select	@PageCount = t.tPageCount,
			@RowCount = t.tRowCount,
			@FreeSpaceMB = t.tFreeSpaceMB
	from (select 
			count(*)													[tPageCount],
			sum(cast(row_count as bigint))								[tRowCount],
			sum(cast(free_space_in_bytes as bigint)) / 1024 / 1024		[tFreeSpaceMB]
			from sys.dm_os_buffer_descriptors) t

	set @Pct_Free_Space = (cast(@FreeSpaceMB as decimal(16,2)) / (cast(@PageCount as decimal(16,2)) * 8 / 1024)) * 100

	
	select 
		@PageCount																			[Buffer_Pool_Page_Count],
		--@PageCount * 8																	[Buffer_Pool_Size_KB],
		@RowCount																			[Row_Count],
		@PageCount * 8 / 1024																[Buffer_Pool_Size_MB],
		cast((cast(@PageCount as decimal(16,2)) * 8 / 1024 / 1024) as decimal(16,2))		[Buffer_Pool_Size_GB],	
		@FreeSpaceMB																		[Free_Space_In_Pages_MB],
		@Pct_Free_Space																		[Free_Space_In_Pages_Percent]

end
			


-- databases	
if @DetailType in ('','database','databases') begin

	select 
		case 
           when ( [database_id] = 32767 ) then 'Resource Database' 
           else db_name( database_id) 
        end																						[Database_Name],
		sum(cast(row_count as bigint))															[Row_Count],
		(count(file_id) * 8) / 1024																[Buffer_Pool_Size_MB],
		--cast((count(file_id) * 8) as decimal(16,2)) / 1024 / 1024								[Buffer_Pool_Size_GB]
		cast((cast((count(file_id) * 8) as decimal(16,2)) / 1024 / 1024) as decimal(16,2))		[Buffer_Pool_Size_GB]
		,sum(cast(free_space_in_bytes as bigint)) / 1024 / 1024									[Free_Space_In_Pages_MB]
	from sys.dm_os_buffer_descriptors b
	group by database_id 
	order by [Buffer_Pool_Size_MB] desc

end



-- dirty / clean buffers	
if @DetailType in ('dirty','clean') begin

	select 
		case 
           when ( [database_id] = 32767 ) then 'Resource Database' 
           else db_name( database_id) 
        end															[Database_Name],
		sum(case 
				 when ([is_modified] = 1 ) then 0 
				 else 1 
			   end) / 128											[Clean_Pages_MB],
		sum(case 
				 when ( [is_modified] = 1 ) then 1 
				 else 0 
			   end) / 128											[Dirty_Pages_MB]
	from sys.dm_os_buffer_descriptors b
	group by database_id
	order by [Database_Name]

end



-- page type
if @DetailType in ('page type','page types') begin

	select 
		case 
           when ( [database_id] = 32767 ) then 'Resource Database' 
           else db_name( database_id) 
        end																						[Database_Name],
		page_type																				[Page_Type],
		sum(cast(row_count as bigint))															[Row_Count],
		(count(file_id) * 8) / 1024																[Buffer_Pool_Size_MB],
		cast((cast((count(file_id) * 8) as decimal(16,2)) / 1024 / 1024) as decimal(16,2))		[Buffer_Pool_Size_GB]
		,sum(cast(free_space_in_bytes as bigint)) / 1024 / 1024									[Free_Space_MB]
	from sys.dm_os_buffer_descriptors b
	group by database_id, [Page_Type]
	order by [Database_Name], [Buffer_Pool_Size_MB], [Row_Count]

end

end







