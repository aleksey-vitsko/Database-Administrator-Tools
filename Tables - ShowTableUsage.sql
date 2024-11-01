

create or alter procedure ShowTableUsage as begin

/****************************************************************** SHOW TABLE USAGE PROCEDURE **************************************************************

Author: Aleksey Vitsko

Version: 1.00

Description: Shows table usage information (inserts, updates, deletes, locks, etc.) within given database

--------------------------------------------------------------------------

History:

2024-11-01 --> Aleksey Vitsko - created stored procedure


*****************************************************************************************************************************************************************/


	SELECT 
		s.[name]															[Schema_Name],
		t.[name]															[Table_Name],
       
		sum(leaf_insert_count) + sum(nonleaf_insert_count)				[Inserts],				-- sum of Leaf and Nonleaf inserts
		sum(leaf_delete_count) +	 sum(iop.nonleaf_delete_count)			[Deletes],				-- sum of Leaf and Nonleaf deletes
		sum(leaf_update_count) +	 sum(iop.nonleaf_update_count)			[Updates],				-- sum of Leaf and Nonleaf updates
		sum(leaf_ghost_count)											[Ghosts],				-- sum of Leaf and Nonleaf ghosted records
      
		sum(row_lock_count)												[RowLocks],
		sum(page_lock_count)												[PageLocks],

		sum(range_scan_count)											[Range_Scans],
		sum(singleton_lookup_count)										[Lookups],
		sum(forwarded_fetch_count)										[Forwarded_Fetches],
		sum(lob_fetch_in_pages)											[LOB_Fetches],
		sum(row_overflow_fetch_in_pages)									[Row_Overflow_Fetches],
	
		sum(index_lock_promotion_count)									[Lock_Escalations],

		sum(row_lock_count) +  
		sum(page_lock_count)  + 
		sum(range_scan_count) + 
		sum(singleton_lookup_count)										[Locks+Scans+Lookups]

	FROM sys.dm_db_index_operational_stats(DB_ID(),NULL,NULL,NULL) AS iop
	
		JOIN sys.indexes AS i 
			ON iop.index_id = i.index_id 
			and iop.[object_id] = i.[object_id]
	
		JOIN sys.tables AS t ON 
			i.[object_id] = t.[object_id] 
	
		join sys.schemas s on
			t.[schema_id] = s.[schema_id]

	GROUP BY s.[name], t.[name]
	ORDER BY [Locks+Scans+Lookups] desc, s.[name], t.[name] 


end
 


