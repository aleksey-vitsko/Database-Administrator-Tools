

/******************************* DML TRIGGER (AFTER-FOR) ******************************************

ABOUT 

Below example shows how to create a DML trigger that captures updates to main table (Employees)
and saves old and new values, along with who, what and when, to a history table (Employees_History)

**************************************************************************************************/


/* main table */

CREATE TABLE Employees (
	ID						int primary key identity,
	Full_Name				varchar(128),
	
	Date_Of_Hire			date,	
	Department				varchar(128),
	
	Last_Check_In			datetime,
	Last_Check_Out			datetime,
	Office_Visits_Count		int default 0,

	Salary					money
	)


INSERT INTO Employees (Full_Name, Date_Of_Hire, Department, Last_Check_In, Last_Check_Out, Salary)
VALUES	('IT Guy 1','2010-01-01','Information Technology','2026-08-10 09:00:00','2026-08-10 17:00:00',123),
		('IT Guy 2','2015-01-01','Information Technology','2026-08-11 09:00:00','2026-08-11 17:00:00',456)



/* history table */

CREATE TABLE Employees_History (
	ID						int primary key identity,
	EmployeeID				int,
	
	Date_Updated			datetime,
	
	Login_Name				varchar(128),
	[Host_Name]				varchar(128),
	
	Column_Updated			varchar(128),
	
	Old_Value				varchar(128),
	New_Value				varchar(128),

	constraint FK_EmpID foreign key (EmployeeID) references Employees (ID) on delete cascade
	)

GO



/* trigger */

create or alter trigger tr_Employees_History
on Employees
with execute as owner
after update
as begin

	if update(Full_Name) begin
		insert into Employees_History (EmployeeID, Date_Updated, Login_Name, [Host_Name], Column_Updated, Old_Value, New_Value)
		select i.ID, getdate(), original_login(), host_name(), 'Full_Name', d.Full_Name, i.Full_Name
		from inserted i
			join deleted d on
				i.ID = d.ID
				and i.Full_Name <> d.Full_Name
	end


	if update(Department) begin
		insert into Employees_History (EmployeeID, Date_Updated, Login_Name, [Host_Name], Column_Updated, Old_Value, New_Value)
		select i.ID, getdate(), original_login(), host_name(), 'Department', d.Department, i.Department
		from inserted i
			join deleted d on
				i.ID = d.ID
				and i.Department <> d.Department
	end


	if update(Date_Of_Hire) begin
		insert into Employees_History (EmployeeID, Date_Updated, Login_Name, [Host_Name], Column_Updated, Old_Value, New_Value)
		select i.ID, getdate(), original_login(), host_name(), 'Date_Of_Hire', d.Date_Of_Hire, i.Date_Of_Hire
		from inserted i
			join deleted d on
				i.ID = d.ID
				and i.Date_Of_Hire <> d.Date_Of_Hire
	end


	if update(Last_Check_In) begin
		insert into Employees_History (EmployeeID, Date_Updated, Login_Name, [Host_Name], Column_Updated, Old_Value, New_Value)
		select i.ID, getdate(), original_login(), host_name(), 'Last_Check_In', convert(varchar,d.Last_Check_In,121), convert(varchar,i.Last_Check_In,121)
		from inserted i
			join deleted d on
				i.ID = d.ID
				and i.Last_Check_In <> d.Last_Check_In
	end


	if update(Last_Check_Out) begin
		insert into Employees_History (EmployeeID, Date_Updated, Login_Name, [Host_Name], Column_Updated, Old_Value, New_Value)
		select i.ID, getdate(), original_login(), host_name(), 'Last_Check_Out', convert(varchar,d.Last_Check_Out,121), convert(varchar,i.Last_Check_Out,121)
		from inserted i
			join deleted d on
				i.ID = d.ID
				and i.Last_Check_Out <> d.Last_Check_Out
	end


	if update(Office_Visits_Count) begin
		insert into Employees_History (EmployeeID, Date_Updated, Login_Name, [Host_Name], Column_Updated, Old_Value, New_Value)
		select i.ID, getdate(), original_login(), host_name(), 'Office_Visits_Count', cast(d.Office_Visits_Count as varchar(128)), cast(i.Office_Visits_Count as varchar(128))
		from inserted i
			join deleted d on
				i.ID = d.ID
				and i.Office_Visits_Count <> d.Office_Visits_Count
	end


	if update(Salary) begin
		insert into Employees_History (EmployeeID, Date_Updated, Login_Name, [Host_Name], Column_Updated, Old_Value, New_Value)
		select i.ID, getdate(), original_login(), host_name(), 'Salary', cast(d.Salary as varchar(128)), cast(i.Salary as varchar(128))
		from inserted i
			join deleted d on
				i.ID = d.ID
				and i.Salary <> d.Salary
	end

end

go



/* test the trigger */

select * from Employees


update Employees
	set Date_Of_Hire = '2011-01-01'
where ID = 1

update Employees
	set Last_Check_In = '2026-08-12 07:00:00',
		Last_Check_Out = '2026-08-12 19:00:00'
where ID = 1

update Employees
	set Salary = 999



select * from Employees_History





