

create or alter procedure ShowTableUsage (
	@DatabaseName			varchar(128) = ''				/* if set this to nvarchar, this will limit @Query parameter to 4000 symbols, which will cause an error */ 
	)
as begin

/****************************************************************** SHOW TABLE USAGE PROCEDURE **************************************************************

Author: Aleksey Vitsko

Version: 2.13

Description: 

Shows table usage information (inserts, updates, deletes, scans, seeks, lookups, locks, latches, etc.) for all tables in a specified database.
For each table (each row), usage statistics is aggregated from all table's indexes.

Useful for finding tables that may not be used.
Disclaimer: Keep in mind that usage stats are reset each time server is restarted, so be careful if retiring anything.

See the rightmost column "Sum_Usage".

Can be called without any parameters - will show tables' usage for current database.
Can be called specifying a database with @DatabaseName parameter - will show tables' usage for specified database.


History:

2025-07-08 --> Aleksey Vitsko - tested on / added support for SQL Server 2016
2025-07-03 --> Aleksey Vitsko - added "Server_Start_Time" and "Database_Name" columns to the output; removed "object_id"
2025-07-02 --> Aleksey Vitsko - added support for SQL Server 2017 (its DMVs doesn't have few columns)
2025-06-04 --> Aleksey Vitsko - minor bugfix plus tested on Azure SQL Database
2025-06-04 --> Aleksey Vitsko - total rework to support all columns from "sys.dm_db_index_operational_stats" and "sys.dm_db_index_usage_stats"
2024-11-05 --> Aleksey Vitsko - added ability to specify target database name (using the @DatabaseName parameter)
2024-11-01 --> Aleksey Vitsko - created stored procedure


Tested on:

- SQL Server 2016 (SP2), 2017 (CU31), 2019 (RTM), 2022 (RTM)
- Azure SQL Managed Instance (SQL 2022 update policy)
- Azure SQL Database


*****************************************************************************************************************************************************************/

	/* parameters */
	declare 
		@Query varchar(max)


	/* if db name is empty, set to current selected database */
	if @DatabaseName = '' begin 
		set @DatabaseName = db_name()
	end

	-- check if specified database name exists at sys.databases
	if not exists (select * from sys.databases where [name] = @DatabaseName) begin
		print 'Specified database ' + @DatabaseName + ' does not exist!'
		print 'Please specify database that exists at sys.databases.'
		print 'Exiting...'
		return
	end


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


	
	/* execute the query */
	
	/* SQL Server 2019-2025 and Azure SQL */
	
	if @Version in ('2019','2022','2025','SQL Azure') or cast(@Version as int) > 2025 begin 
	
		set @Query = 'SELECT 
			
			(select cast(sqlserver_start_time as smalldatetime) from sys.dm_os_sys_info )		[Server_Start_Time],
			''' + @DatabaseName + '''											[Database_Name],
			
			s.[name]															[Schema_Name],
			t.[name]															[Table_Name],
			--t.[object_id],
			

			isnull(sum(leaf_insert_count),0) +	isnull(sum(nonleaf_insert_count),0)					[Inserts],				-- sum of Leaf and Nonleaf inserts
			isnull(sum(leaf_delete_count),0) +	 isnull(sum(iop.nonleaf_delete_count),0)			[Deletes],				-- sum of Leaf and Nonleaf deletes
			isnull(sum(leaf_update_count),0) +	 isnull(sum(iop.nonleaf_update_count),0)			[Updates],				-- sum of Leaf and Nonleaf updates
			isnull(sum(leaf_ghost_count),0)												[Ghosts],				-- sum of Leaf and Nonleaf ghosted records
      
			isnull(sum(range_scan_count),0)												[Range_Scans],
			isnull(sum(singleton_lookup_count),0)											[Singleton_Lookups],

			isnull(sum(ius.user_seeks),0)													[User_Seeks],
			isnull(sum(ius.user_scans),0)													[User_Scans],
			isnull(sum(ius.user_lookups),0)												[User_Lookups],
			isnull(sum(ius.user_updates),0)												[User_Updates],

			isnull(sum(ius.system_seeks),0)												[System_Seeks],
			isnull(sum(ius.system_scans),0)												[System_Scans],
			isnull(sum(ius.system_lookups),0)												[System_Lookups],
			isnull(sum(ius.system_updates),0)												[System_Updates],


			isnull(sum(row_lock_count),0)													[RowLocks],
			isnull(sum(page_lock_count),0)												[PageLocks],

			isnull(sum(page_latch_wait_count),0)											[Latch_Waits],
			isnull(sum(page_io_latch_wait_count),0)										[IO_Latch_Waits],

			isnull(sum(tree_page_latch_wait_count),0)										[Tree_Latch_Waits],
			isnull(sum(tree_page_io_latch_wait_count),0)									[Tree_IO_Latch_Waits],

		

			isnull(sum(forwarded_fetch_count),0)											[Forwarded_Fetches],
			isnull(sum(lob_fetch_in_pages),0)												[LOB_Fetches],
			isnull(sum(lob_orphan_create_count),0)										[LOB_Orphan_Creates],
			isnull(sum(lob_orphan_insert_count),0)										[LOB_Orphan_Inserts],
			
			isnull(sum(column_value_push_off_row_count),0)								[ColVal_Off_Row],
			isnull(sum(column_value_pull_in_row_count),0)									[ColVal_In_Row],
		
			isnull(sum(row_overflow_fetch_in_pages),0)									[Row_Overflow_Fetches],
	
			isnull(sum(index_lock_promotion_attempt_count),0)								[Escalation_Attempts],
			isnull(sum(index_lock_promotion_count),0)										[Lock_Escalations],

			isnull(sum(page_compression_attempt_count),0)									[Page_Compression_Attempts],
			isnull(sum(page_compression_success_count),0)									[Page_Compression_Success],

			isnull(sum(version_generated_inrow),0)										[Version_Generated_In_Row],
			isnull(sum(version_generated_offrow),0)										[Version_Generated_Off_Row],

			isnull(sum(ghost_version_inrow),0)											[Ghost_Version_In_Row],
			isnull(sum(ghost_version_offrow),0)											[Ghost_Version_Off_Row],

			isnull(sum(insert_over_ghost_version_inrow),0)								[Insert_Over_Ghost_In_Row],
			isnull(sum(insert_over_ghost_version_offrow),0)								[Insert_Over_Ghost_Off_Row],

		
			isnull(sum(leaf_insert_count),0) +	
			isnull(sum(nonleaf_insert_count),0) + 
			isnull(sum(leaf_delete_count),0) +	 
			isnull(sum(iop.nonleaf_delete_count),0) +
			isnull(sum(leaf_update_count),0) +	 
			isnull(sum(iop.nonleaf_update_count),0) +
			isnull(sum(leaf_ghost_count),0)	+
			isnull(sum(range_scan_count),0) +
			isnull(sum(singleton_lookup_count),0) +
			isnull(sum(ius.user_seeks),0) +
			isnull(sum(ius.user_scans),0) +
			isnull(sum(ius.user_lookups),0) +
			isnull(sum(ius.user_updates),0) +
			isnull(sum(ius.system_seeks),0) +
			isnull(sum(ius.system_scans),0) +
			isnull(sum(ius.system_lookups),0) +
			isnull(sum(ius.system_updates),0) +
			isnull(sum(row_lock_count),0) +
			isnull(sum(page_lock_count),0) +
			isnull(sum(page_latch_wait_count),0) +
			isnull(sum(page_io_latch_wait_count),0) +
			isnull(sum(tree_page_latch_wait_count),0) +
			isnull(sum(tree_page_io_latch_wait_count),0) +
			isnull(sum(forwarded_fetch_count),0) +
			isnull(sum(lob_fetch_in_pages),0) +
			isnull(sum(lob_orphan_create_count),0) +
			isnull(sum(lob_orphan_insert_count),0) +
			isnull(sum(column_value_push_off_row_count),0) +
			isnull(sum(column_value_pull_in_row_count),0) +
			isnull(sum(row_overflow_fetch_in_pages),0) +
			isnull(sum(index_lock_promotion_attempt_count),0) +
			isnull(sum(index_lock_promotion_count),0) +
			isnull(sum(page_compression_attempt_count),0) +
			isnull(sum(page_compression_success_count),0) +
			isnull(sum(version_generated_inrow),0) +
			isnull(sum(version_generated_offrow),0)	 +
			isnull(sum(ghost_version_inrow),0) +
			isnull(sum(ghost_version_offrow),0) +
			isnull(sum(insert_over_ghost_version_inrow),0) +
			isnull(sum(insert_over_ghost_version_offrow),0)				[Sum_Usage]
		

		FROM ' + @DatabaseName + '.sys.tables t

			left join ' + @DatabaseName + '.sys.schemas s on
				t.[schema_id] = s.[schema_id]
	
			left join ' + @DatabaseName + '.sys.dm_db_index_operational_stats(DB_ID(''' + @DatabaseName + '''),NULL,NULL,NULL) iop on
				t.[object_id] = iop.[object_id]

			left join ' + @DatabaseName + '.sys.indexes i on 
				t.[object_id]  = i.[object_id]
				and iop.index_id = i.index_id 
	
			left join ' + @DatabaseName + '.sys.dm_db_index_usage_stats ius on
				t.[object_id] = ius.[object_id]

		GROUP BY s.[name], t.[name], t.[object_id]
		ORDER BY [Sum_Usage] desc, s.[name], t.[name]'


	end


	/* SQL Server 2016-2017 */

	if @Version in ('2016','2017') begin

		set @Query = 'SELECT 
			
			(select cast(sqlserver_start_time as smalldatetime) from sys.dm_os_sys_info )		[Server_Start_Time],
			''' + @DatabaseName + '''											[Database_Name],

			s.[name]															[Schema_Name],
			t.[name]															[Table_Name],
			--t.[object_id],

			isnull(sum(leaf_insert_count),0) +	isnull(sum(nonleaf_insert_count),0)					[Inserts],				-- sum of Leaf and Nonleaf inserts
			isnull(sum(leaf_delete_count),0) +	 isnull(sum(iop.nonleaf_delete_count),0)			[Deletes],				-- sum of Leaf and Nonleaf deletes
			isnull(sum(leaf_update_count),0) +	 isnull(sum(iop.nonleaf_update_count),0)			[Updates],				-- sum of Leaf and Nonleaf updates
			isnull(sum(leaf_ghost_count),0)												[Ghosts],				-- sum of Leaf and Nonleaf ghosted records
      
			isnull(sum(range_scan_count),0)												[Range_Scans],
			isnull(sum(singleton_lookup_count),0)											[Singleton_Lookups],

			isnull(sum(ius.user_seeks),0)													[User_Seeks],
			isnull(sum(ius.user_scans),0)													[User_Scans],
			isnull(sum(ius.user_lookups),0)												[User_Lookups],
			isnull(sum(ius.user_updates),0)												[User_Updates],

			isnull(sum(ius.system_seeks),0)												[System_Seeks],
			isnull(sum(ius.system_scans),0)												[System_Scans],
			isnull(sum(ius.system_lookups),0)												[System_Lookups],
			isnull(sum(ius.system_updates),0)												[System_Updates],


			isnull(sum(row_lock_count),0)													[RowLocks],
			isnull(sum(page_lock_count),0)												[PageLocks],

			isnull(sum(page_latch_wait_count),0)											[Latch_Waits],
			isnull(sum(page_io_latch_wait_count),0)										[IO_Latch_Waits],

			isnull(sum(tree_page_latch_wait_count),0)										[Tree_Latch_Waits],
			isnull(sum(tree_page_io_latch_wait_count),0)									[Tree_IO_Latch_Waits],

		

			isnull(sum(forwarded_fetch_count),0)											[Forwarded_Fetches],
			isnull(sum(lob_fetch_in_pages),0)												[LOB_Fetches],
			isnull(sum(lob_orphan_create_count),0)										[LOB_Orphan_Creates],
			isnull(sum(lob_orphan_insert_count),0)										[LOB_Orphan_Inserts],
			
			isnull(sum(column_value_push_off_row_count),0)								[ColVal_Off_Row],
			isnull(sum(column_value_pull_in_row_count),0)									[ColVal_In_Row],
		
			isnull(sum(row_overflow_fetch_in_pages),0)									[Row_Overflow_Fetches],
	
			isnull(sum(index_lock_promotion_attempt_count),0)								[Escalation_Attempts],
			isnull(sum(index_lock_promotion_count),0)										[Lock_Escalations],

			isnull(sum(page_compression_attempt_count),0)									[Page_Compression_Attempts],
			isnull(sum(page_compression_success_count),0)									[Page_Compression_Success],

		
			isnull(sum(leaf_insert_count),0) +	
			isnull(sum(nonleaf_insert_count),0) + 
			isnull(sum(leaf_delete_count),0) +	 
			isnull(sum(iop.nonleaf_delete_count),0) +
			isnull(sum(leaf_update_count),0) +	 
			isnull(sum(iop.nonleaf_update_count),0) +
			isnull(sum(leaf_ghost_count),0)	+
			isnull(sum(range_scan_count),0) +
			isnull(sum(singleton_lookup_count),0) +
			isnull(sum(ius.user_seeks),0) +
			isnull(sum(ius.user_scans),0) +
			isnull(sum(ius.user_lookups),0) +
			isnull(sum(ius.user_updates),0) +
			isnull(sum(ius.system_seeks),0) +
			isnull(sum(ius.system_scans),0) +
			isnull(sum(ius.system_lookups),0) +
			isnull(sum(ius.system_updates),0) +
			isnull(sum(row_lock_count),0) +
			isnull(sum(page_lock_count),0) +
			isnull(sum(page_latch_wait_count),0) +
			isnull(sum(page_io_latch_wait_count),0) +
			isnull(sum(tree_page_latch_wait_count),0) +
			isnull(sum(tree_page_io_latch_wait_count),0) +
			isnull(sum(forwarded_fetch_count),0) +
			isnull(sum(lob_fetch_in_pages),0) +
			isnull(sum(lob_orphan_create_count),0) +
			isnull(sum(lob_orphan_insert_count),0) +
			isnull(sum(column_value_push_off_row_count),0) +
			isnull(sum(column_value_pull_in_row_count),0) +
			isnull(sum(row_overflow_fetch_in_pages),0) +
			isnull(sum(index_lock_promotion_attempt_count),0) +
			isnull(sum(index_lock_promotion_count),0) +
			isnull(sum(page_compression_attempt_count),0) +
			isnull(sum(page_compression_success_count),0) 			[Sum_Usage]
		

		FROM ' + @DatabaseName + '.sys.tables t

			left join ' + @DatabaseName + '.sys.schemas s on
				t.[schema_id] = s.[schema_id]
	
			left join ' + @DatabaseName + '.sys.dm_db_index_operational_stats(DB_ID(''' + @DatabaseName + '''),NULL,NULL,NULL) iop on
				t.[object_id] = iop.[object_id]

			left join ' + @DatabaseName + '.sys.indexes i on 
				t.[object_id]  = i.[object_id]
				and iop.index_id = i.index_id 
	
			left join ' + @DatabaseName + '.sys.dm_db_index_usage_stats ius on
				t.[object_id] = ius.[object_id]

		GROUP BY s.[name], t.[name], t.[object_id]
		ORDER BY [Sum_Usage] desc, s.[name], t.[name]'

	end


	-- print @Query
	-- print len(@Query)

	exec (@Query)

	-- exec ShowTableUsage

end
 


