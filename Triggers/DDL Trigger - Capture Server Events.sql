

/***************************** DDL TRIGGER - SERVER *********************************************

ABOUT 

Below example shows how to create a DDL trigger that captures any changes to server level
objects or permissions via DDL events.

EXECUTE AS is used for example purposes.
Not needed if account executing DDL statements has full privileges on a server.

**************************************************************************************************/


/* logging table in master database */

create table [master]..DDL_Audit_Srv (
    ID                  int identity primary key,
   
    EventType           nvarchar(128),
    TSQLCommand         nvarchar(MAX),

    ObjectName          nvarchar(128),
    ObjectType          nvarchar(128),
       
    LoginName           nvarchar(128),
    HostName            nvarchar(128),

    EventTime           datetime default getdate()
) with (data_compression=page);



/* login for EXECUTE AS */
use [master]

create login DDL_Audit_Login with password = '****************'   /* type valid password */
create user DDL_Audit_Login for login DDL_Audit_Login
grant insert on DDL_Audit_Srv to DDL_Audit_Login



/* trigger in master database */

USE [master]
GO

CREATE or ALTER TRIGGER tr_DDL_Srv
ON ALL SERVER
WITH EXECUTE AS 'DDL_Audit_Login'
FOR DDL_SERVER_LEVEL_EVENTS
AS BEGIN
    
        DECLARE @EventXML XML = EVENTDATA();

        INSERT INTO [master].dbo.DDL_Audit_Srv (EventType, TSQLCommand, ObjectName, ObjectType,  LoginName, HostName)
        SELECT
            isnull(@EventXML.value('(/EVENT_INSTANCE/EventType)[1]', 'NVARCHAR(128)'),''),
            isnull(@EventXML.value('(/EVENT_INSTANCE/TSQLCommand)[1]', 'NVARCHAR(MAX)'),''),

            isnull(@EventXML.value('(/EVENT_INSTANCE/ObjectName)[1]', 'NVARCHAR(128)'),''),
            isnull(@EventXML.value('(/EVENT_INSTANCE/ObjectType)[1]', 'NVARCHAR(128)'),''),
            
            original_login(),
            host_name()
   
END;





