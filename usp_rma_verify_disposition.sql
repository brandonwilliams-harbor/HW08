USE [AAD]
GO


SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





ALTER PROCEDURE [dbo].[usp_rma_verify_disposition]
	@in_employee_id			NVARCHAR(10),
	@in_device_id			NVARCHAR(60),
	@in_wh_id				NVARCHAR(10),
	@in_fork_id				NVARCHAR(50),
	@in_tran_type			NVARCHAR(3),
	@out_sysshort			NVARCHAR(20)	OUTPUT,
	@out_deadlock_flag		INT				OUTPUT,
/*END OF COMMON INPUTS*/
	@in_dialog_field		NVARCHAR(MAX), 
	@in_item_number         NVARCHAR(50),
	@in_rma_number          NVARCHAR(30),
	@out_disposition		NVARCHAR(10)	OUTPUT,
	@out_flag_crte_inv		INT				OUTPUT,
	@in_debug				INT = 0
AS


/****************************************************************************************************************************************************************************************
 Description: Validate dispoistion for RMA receipt process (screen 8.2) 

 Version	Date		Initials	Repo    Notes
 -------	---------	--------	-----   ---------------------------------------------------------------------------------------------------    
 1.0		20170617	SJD					Created 
 2.0		20260819	BEW-HWF		HW08	Added logic to present error when item is not active. 

****************************************************************************************************************************************************************************************/


BEGIN
SET NOCOUNT ON; -- Always use NOCOUNT for All procedures

DECLARE @error_num			NVARCHAR(MAX),
		@error_msg			NVARCHAR(MAX),
		@item_hu_indic		NCHAR(1),
		@loc_type			NCHAR(1)

BEGIN TRY--Put procedure in Try/Catch so deadlocks can be caught
	--Clear Deadlock Flag and other variables
	SELECT
		@out_deadlock_flag = 0,
		@out_sysshort = NULL,
		@out_flag_crte_inv = 0

	SELECT @out_disposition = @in_dialog_field
	  , @out_flag_crte_inv = CASE WHEN @in_dialog_field = 'INVENTORY' THEN 1 ELSE 0 END
		FROM t_reason WITH (NOLOCK)
	WHERE type = 'RETURNS'
		AND disposition = @in_dialog_field


	IF @@ROWCOUNT = 0
	BEGIN
		SET @out_sysshort = 'INVALID DISPOSITION'
		GOTO EXITLABEL
	END
--2.0 Begin 
	IF EXISTS ( 
		SELECT 1 
		FROM t_item_master itm WITH (NOLOCK)
		WHERE wh_id = @in_wh_id 
			AND item_number = @in_item_number 
			AND ISNULL(itm.host_status, 0) <> 0 
			AND @in_dialog_field = 'INVENTORY' ) 
	BEGIN
		SET @out_sysshort = 'ITEM NOT ACTIVE'
		GOTO EXITLABEL
	END
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

	SELECT @out_sysshort = LEFT('SQL Error ' + @error_num , 20)
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


