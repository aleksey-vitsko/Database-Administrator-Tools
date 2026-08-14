
/******************************* DML TRIGGER (INSTEAD OF) ******************************************

ABOUT 

Below example shows how to create a very simple DML trigger that prints a line instead of 
deleting a records from a table. This is for example purposes only.

**************************************************************************************************/


/* table */

create table AutoParts (
	ID					int identity primary key,
	PartName			varchar(128),
	Price				money
	)

insert into AutoParts (PartName, Price)
values ('Wheel',123)

go


/* trigger */

create trigger tr_AutoParts_Prevent_Delete
on AutoParts
instead of delete
as begin
	print 'No deletes today (and tomorrow)'
end

go


/* test and verify */

delete from AutoParts

select * from AutoParts


