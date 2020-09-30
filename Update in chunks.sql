


set nocount on

declare 
	@ChunkSize				int = 1000,							-- count rows to remove in 1 chunk 
	@TimeBetweenChunks		char(8) = '00:00:01', 				-- interval between chunks
	
	@Start					datetime,
	@End					datetime,
	@Diff					int,
	
	@MessageText			varchar(500),
	
	@counter				int = 1,
	@RowCount				int = 1,
	@TotalRowsToUpdate		bigint,
	@TotalRowsLeft			bigint
	


-- total row count to update
set @TotalRowsToUpdate = (select count(*)
							from [Table1]
								join [Table2] on
									btid = tBtID
							where	btStatusID = 81)


set @TotalRowsLeft = @TotalRowsToUpdate
set @MessageText = 'Total Rows to Update = ' + cast(@TotalRowsLeft as varchar) raiserror (@MessageText,0,1) with nowait
print ''



-- begin cycle
while @RowCount > 0 begin

	set @Start = getdate()

	-- update packages
	update top (@ChunkSize) bti
		set	btstatusid = 154,
			btType = 1
	from [Table1] bti
		join [Table2] on
			btid = tBtID
	where	btStatusID = 81
	

	set @RowCount = @@ROWCOUNT

	-- measure time
	set @End = getdate()
	set @Diff = datediff(ms,@Start,@End)

	set @TotalRowsLeft = @TotalRowsLeft - @RowCount
	set @MessageText = cast(@counter as varchar) + ' - Updated ' + cast(@RowCount as varchar) + ' rows in ' + cast(@Diff as varchar) + ' milliseconds - total ' + cast(@TotalRowsLeft as varchar) + ' rows left...'

	-- print progress message
	raiserror (@MessageText,0,1) with nowait


	set @counter += 1

	WAITFOR DELAY @TimeBetweenChunks

end



