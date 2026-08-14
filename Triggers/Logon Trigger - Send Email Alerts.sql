

/************************************ LOGON TRIGGER  *********************************************

ABOUT 

Below example shows how to create a LOGON trigger that sends email alerts whenever certain login
has been made from a certain computer.

In this scenario we use "EXECUTE AS" in a trigger to gain permissions to send emails.


**************************************************************************************************/


/* login for EXECUTE AS */
use [master]
create login SendEmailsLogin with password = '*****************!'   /* type valid password */

use [msdb]
create user SendEmailsLogin for login SendEmailsLogin
alter role [DatabaseMailUserRole] add member SendEmailsLogin



/* trigger in master database */

USE [master]
GO

CREATE or ALTER TRIGGER tr_Logon_Email_Alert
ON ALL SERVER
WITH EXECUTE AS 'SendEmailsLogin'
FOR LOGON
AS BEGIN
    
        DECLARE 
            @Original_Login     varchar(128),
            @Host_Name          varchar(128)

        SET @Original_Login = original_login()
        SET @Host_Name = host_name()


        IF (@Original_Login = 'SomeLogin' and @Host_Name = 'SomeComputer') BEGIN

            DECLARE @MsgText varchar(1000)

            /* form the message text */
            SET @MsgText = @Original_Login + ' was used from computer: ' + @Host_Name

            /* send email alert */
			EXEC msdb.dbo.sp_send_dbmail
				@profile_name = 'DBMail_ProfileName',      /* specify dbmail profile */
				@recipients = 'DBA@domain.com',  
				@body = @MsgText, 
				@subject = 'Login Report'  

        END
   
END;


ENABLE TRIGGER tr_Logon_Email_Alert ON ALL SERVER
GO
