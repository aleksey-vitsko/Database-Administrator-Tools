

/***************************** DDL TRIGGER - DATABASE *********************************************

ABOUT 

Below example shows how to create a DDL trigger that captures any changes to schema, objects
and permissions inside a database, and a scenario when user executing the DDL command can create 
table and alter schema, but is not allowed to insert into logging table.

We use "EXECUTE AS" in a trigger to resolve this permission issue.

**************************************************************************************************/


/* logging table */

CREATE TABLE dbo.DDL_Audit (
    ID                  bigint identity(1,1) primary key,
   
    EventType           nvarchar(128),
    TSQLCommand         nvarchar(MAX),
   
    DatabaseName        nvarchar(128),
    SchemaName          nvarchar(128),
    ObjectName          nvarchar(128),
    ObjectType          nvarchar(128),
   
    LoginName           nvarchar(128),
    HostName            nvarchar(128),

    EventTime           datetime default getdate(),
) with (data_compression=page);


/* user for the EXECUTE AS */
create user DDL_Audit_User without login
grant insert on DDL_Audit to DDL_Audit_User

go


/* trigger */

CREATE or ALTER TRIGGER tr_DDL
ON DATABASE
WITH EXECUTE AS 'DDL_Audit_User'
FOR DDL_DATABASE_LEVEL_EVENTS
AS BEGIN
    SET NOCOUNT ON;

        DECLARE @EventData XML = EVENTDATA()
                    
        INSERT INTO dbo.DDL_Audit (EventType, TSQLCommand, DatabaseName, SchemaName, ObjectName, ObjectType, LoginName, HostName)
        SELECT  
            isnull(@EventData.value('(/EVENT_INSTANCE/EventType)[1]', 'NVARCHAR(128)'),''), 
            isnull(@EventData.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'NVARCHAR(MAX)'),''), 
            
            isnull(@EventData.value('(/EVENT_INSTANCE/DatabaseName)[1]', 'NVARCHAR(128)'),''), 
            isnull(@EventData.value('(/EVENT_INSTANCE/SchemaName)[1]', 'NVARCHAR(128)'),''), 
            isnull(@EventData.value('(/EVENT_INSTANCE/ObjectName)[1]', 'NVARCHAR(128)'),''),
            isnull(@EventData.value('(/EVENT_INSTANCE/ObjectType)[1]', 'NVARCHAR(128)'),''),
            
            original_login(), 
            host_name()
     
END;
GO



/* test the trigger */

create user User1 without login
grant create table to User1
grant alter on schema::dbo to User1


execute as user = 'User1'
    create table Test1 (ID int)
revert





