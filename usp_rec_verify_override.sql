USE [AAD] 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO




ALTER PROCEDURE [dbo].[usp_rec_verify_override]
	@in_employee_id			NVARCHAR(10),
	@in_device_id			NVARCHAR(60),
	@in_wh_id				NVARCHAR(10),
	@in_fork_id				NVARCHAR(50),
	@in_menu_process		NVARCHAR(130),
	@in_tran_type			NVARCHAR(3),
	@out_sysshort			NVARCHAR(20)	OUTPUT,
	@out_deadlock_flag		INT				OUTPUT,
	@in_staging_location	NVARCHAR(50),
	@in_appointment_id		INT,
	@in_po_number			NVARCHAR(30),
	@in_dialog_field		NVARCHAR(MAX) --override
AS

/****************************************************************************************************************************************************************************************
  Description: Verifies override for po receipt and replen under min priority work 

  Version	Date		Intials		repo	Notes
  -------	--------	-------		-----	------------------------------------------------
  1.0		20160328	STS					Created
  2.0       20260819    BEW-HWF     HW08    Inserting into t_exception_log for reporting needs 

*****************************************************************************************************************************************************************************************/

BEGIN
SET NOCOUNT ON; -- Always use NOCOUNT for All procedures

DECLARE @error_num			INT,
		@error_msg			NVARCHAR(MAX),
		@item_number		NVARCHAR(30),
		@lot_number			NVARCHAR(30), 
        @tran_type          NVARCHAR(5),    --2.0 Begin 
        @description        NVARCHAR(250),
        @error_message      NVARCHAR(1000)  --2.0 End 

		

BEGIN TRY--Put procedure in Try/Catch so deadlocks can be caught
	--Clear Deadlock Flag and other variables
	SELECT
		@out_deadlock_flag = 0,
		@out_sysshort = NULL

	--Override code must exist on an employee for the warehouse
	IF NOT EXISTS
	(	SELECT 1
		FROM t_employee WITH (NOLOCK)
		WHERE wh_id = @in_wh_id
		AND supervisor_override = @in_dialog_field
	)
	BEGIN
		SET @out_sysshort = 'INVALID OVERRIDE' 
		GOTO EXITLABEL
	END

--2.0 Begin 
    IF @in_menu_process = '_Replenishment-RPN' --repln under min override 
    BEGIN 
        SELECT @tran_type = 320
            ,@description = 'Replen supervisor override'
            ,@error_message = @in_dialog_field + ' used for replen supervisor override'
    END 
    IF @in_tran_type = 151 --Po receipt variance 
    BEGIN 
        SELECT @tran_type = @in_tran_type
            ,@description = 'Receiving overage supervisor override'
            ,@error_message = @in_dialog_field + ' used for receiving overage supervisor override'
    END 
        INSERT INTO t_exception_log
        ( 
            tran_type, 
            [description],
            exception_date, 
            exception_time, 
            employee_id, 
            wh_id, 
            entered_value, 
            error_message 
        )

        SELECT @tran_type, 
                @description, 
                CAST(GETDATE() AS DATE),
                CAST(GETDATE() AS TIME),
                @in_employee_id, 
                @in_wh_id,
                @in_dialog_field, 
                @error_message
--2.0 End 


END TRY
BEGIN CATCH
  
	SELECT 
		@error_num = ERROR_NUMBER(),
		@error_msg = CONVERT(NVARCHAR, ERROR_NUMBER())+' '+ERROR_MESSAGE()

	IF @@TRANCOUNT > 0
	BEGIN
		ROLLBACK TRAN
	END

	SELECT @out_sysshort = LEFT('SQL Error ' + CONVERT(VARCHAR(12), @error_num) , 20)
	RAISERROR(@error_msg, 0, 1)

	IF @error_num = 1205	--Check for Deadlock
	BEGIN
		SET @out_deadlock_flag = 1
		RETURN
	END
	ELSE
	BEGIN
		RAISERROR(@error_msg,18,1)
		RETURN
	END
END CATCH

EXITLABEL:
	
	RETURN

END




GO
