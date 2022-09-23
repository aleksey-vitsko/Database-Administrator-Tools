
-- use [master]


create or alter procedure VirtualFileStats as begin


/********************************************************** Virtual File Stats Procedure **********************************************************

Description:

This query was taken directly from Brent Ozar's website and turned into stored procedure for convenience. 
Shows virtual IO stats (reads, writes, total GB read, total GB written, average reads in milliseconds, average writes in milliseconds, etc.) 
for database data and log files.

https://www.brentozar.com/blitz/slow-storage-reads-writes/


***************************************************************************************************************************************************/


SELECT  DB_NAME(a.database_id) AS [Database Name] ,
        b.name + N' [' + b.type_desc COLLATE SQL_Latin1_General_CP1_CI_AS + N']' AS [Logical File Name] ,
        UPPER(SUBSTRING(b.physical_name, 1, 2)) AS [Drive] ,
        CAST(( ( a.size_on_disk_bytes / 1024.0 ) / (1024.0*1024.0) ) AS DECIMAL(9,2)) AS [Size (GB)] ,
        a.io_stall_read_ms AS [Total IO Read Stall] ,
        a.num_of_reads AS [Total Reads] ,
        CASE WHEN a.num_of_bytes_read > 0 
            THEN CAST(a.num_of_bytes_read/1024.0/1024.0/1024.0 AS NUMERIC(23,1))
            ELSE 0 
        END AS [GB Read],
        CAST(a.io_stall_read_ms / ( 1.0 * a.num_of_reads ) AS INT) AS [Avg Read Stall (ms)] ,
        CASE 
            WHEN b.type = 0 THEN 30 /* data files */
            WHEN b.type = 1 THEN 5 /* log files */
            ELSE 0
        END AS [Max Rec Read Stall Avg],
        a.io_stall_write_ms AS [Total IO Write Stall] ,
        a.num_of_writes [Total Writes] ,
        CASE WHEN a.num_of_bytes_written > 0 
            THEN CAST(a.num_of_bytes_written/1024.0/1024.0/1024.0 AS NUMERIC(23,1))
            ELSE 0 
        END AS [GB Written],
        CAST(a.io_stall_write_ms / ( 1.0 * a.num_of_writes ) AS INT) AS [Avg Write Stall (ms)] ,
        CASE 
            WHEN b.type = 0 THEN 30 /* data files */
            WHEN b.type = 1 THEN 2 /* log files */
            ELSE 0
        END AS [Max Rec Write Stall Avg] ,
        b.physical_name AS [Physical File Name],
        CASE
            WHEN b.name = 'tempdb' THEN 'N/A'
            WHEN b.type = 1 THEN 'N/A' /* log files */
            ELSE 'PAGEIOLATCH*'
        END AS [Read-Related Wait Stat],
        CASE
            WHEN b.type = 1 THEN 'WRITELOG' /* log files */
            WHEN b.name = 'tempdb' THEN 'xxx' /* tempdb data files */
            WHEN b.type = 0 THEN 'ASYNC_IO_COMPLETION' /* data files */
            ELSE 'xxx'
        END AS [Write-Related Wait Stat],
        GETDATE() AS [Sample Time],
        b.type_desc
	FROM    sys.dm_io_virtual_file_stats(NULL, NULL) AS a
			INNER JOIN sys.master_files AS b ON a.file_id = b.file_id
												AND a.database_id = b.database_id
	WHERE   a.num_of_reads > 0
			AND a.num_of_writes > 0
	ORDER BY  CAST(a.io_stall_read_ms / ( 1.0 * a.num_of_reads ) AS INT) DESC


end

