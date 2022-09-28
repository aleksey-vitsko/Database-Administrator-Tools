# Database-Administrator-Tools
Scripts and stored procedures for Microsoft SQL Server Database Administrators

Quick overview of stored procedures:

ScriptLoginPermissions – scripts server-level and database-level permissions, role memberships for specified login
ViewServerProperties – shows host OS, server machine, SQL instance-level properties and configuration options, and more
MemoryManagerInfo – shows how SQL Server is using memory
BufferPoolSize – break down of the Buffer Pool
ServerSpaceUsage – shows how much storage space SQL Server instance consumes, and details for files and their fullness
DatabaseSpaceUsage – help DBA quickly identify which tables are the largest in a specified database, and table/index/reserved/free space in the database
TempDBInfo – hows detailed information on current state of TempDB database
ViewSessionsConnections – use this to learn details about sessions connected to your system
VirtualFileStats – taken directly from Brent Ozar’s website and turned into stored procedure for convenience. Shows virtual IO stats

Detailed instructions:

https://docs.google.com/document/d/1-icqTGFTR_4rUG9l7Vh6GgNDjbKYfy_f/edit?usp=sharing&ouid=111236143224136449685&rtpof=true&sd=true

Hope you will find tools useful!
