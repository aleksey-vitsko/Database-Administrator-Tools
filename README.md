# Database-Administrator-Tools
Scripts and stored procedures for Microsoft SQL Server Database Administrators

Quick overview of stored procedures:

--------------------------------------------------------------------------------------------------------------------------------------

ScriptLoginPermissions – scripts server-level and database-level permissions, role and group memberships for specified login.    

ShowTableUsage - shows which tables are used (inserts,updates,deletes,locks,scans,seeks, etc.) within a database, and which are not.

ViewServerProperties – shows number of physical and logical cores, sockets, memory, host OS info, server machine info, SQL instance-level properties and configuration options, and more.  

MemoryManagerInfo – shows break down of how SQL Server instance is using memory.

BufferPoolSize – break down of the Buffer Pool.

ServerSpaceUsage – shows how much storage space SQL Server instance consumes, and details for files and their fullness.

DatabaseSpaceUsage – help DBA quickly identify which tables are the largest in a specified database, and table/index/reserved/free space for each table in the database.

TempDBInfo – shows detailed information on current state of TempDB database, file fullness, etc.

ViewSessionsConnections – use this to learn details about sessions connected to your system.

--------------------------------------------------------------------------------------------------------------------------------------

Detailed instructions:

https://docs.google.com/document/d/1-icqTGFTR_4rUG9l7Vh6GgNDjbKYfy_f/edit?usp=sharing&ouid=111236143224136449685&rtpof=true&sd=true

Hope you will find tools useful!
