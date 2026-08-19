USE [AAD] 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


ALTER PROCEDURE [dbo].[usp_ww_inbound_appointment_delete_po]
	@in_ww_username		NVARCHAR(MAX),
	@in_wh_id			VARCHAR(10),
	@in_po_number       nvarchar(30),
	@in_appointment_id	NVARCHAR(250)

AS
BEGIN
SET NOCOUNT ON;

/****************************************************************************************************************************************************************************************
  Description: Webwise Delete, Inbound Appointment PO. page 1712 

  Version	Date		Intials		repo	Notes
  -------	--------	-------		-----	------------------------------------------------
  1.0		20170327	SJD					Created
  2.0       20260819    BEW-HWF     HW08    Inserting into t_tran_log_holding for reporting needs 

*****************************************************************************************************************************************************************************************/

	
BEGIN TRY
	DECLARE @error_num INT
	DECLARE @error_msg NVARCHAR(MAX)
	DECLARE @po_type NVARCHAR(30)
	DECLARE @vendor_name NVARCHAR(50) --2.0
	DECLARE @vendor_code NVARCHAR(30) --2.0 

	IF EXISTS (SELECT * FROM  t_receipt rec WITH(NOLOCK)
	WHERE  rec.wh_id = @in_wh_id
		AND rec.po_number = @in_po_number)
		RAISERROR('Can''t remove Recieved PO',18,1)

	SELECT TOP 1
		@po_type = [type]
	FROM t_po_master WITH (NOLOCK)
	WHERE po_number = @in_po_number
	AND wh_id = @in_wh_id

	IF @po_type = 'TR'
	BEGIN
		RAISERROR('Can''t remove Transfer PO from this screen',18,1)
	END

	DELETE t_appointment_po
	WHERE appointment_id = @in_appointment_id
		AND po_number = @in_po_number
		AND wh_id = @in_wh_id

--2. Begin 
	SELECT @vendor_code = v.vendor_code 
		,@vendor_name = v.vendor_name 
	FROM t_po_master pom WITH (NOLOCK)
	INNER JOIN t_vendor v WITH (NOLOCK)
		ON pom.vendor_code = v.vendor_code 


	INSERT INTO t_tran_log_holding
	(
		tran_type
		,[description]
		,start_tran_date
		,start_tran_time
		,end_tran_date
		,end_tran_time
		,employee_id
		,wh_id
		,tran_qty
		,appointment_id
		,po_number
		,control_number
		,generic_attribute_1
		,generic_attribute_2

	)
	SELECT 
		'103'
		,'Delete PO from Appointment'
		,GETDATE()
		,GETDATE()
		,GETDATE()
		,GETDATE()
		,ISNULL(dbo.usf_get_employee_from_ww_user(@in_ww_username, @in_wh_id),@in_ww_username)--COALESCE((SELECT TOP 1 id FROM t_employee WITH(NOLOCK) WHERE ww_username = @in_ww_username),@in_ww_username)
		,@in_wh_id
		,1
		,@in_appointment_id
		,@in_po_number
		,@in_po_number
		,@vendor_code
		,@vendor_name 

--2.0 End 


	GOTO EXIT_LABEL
END TRY

BEGIN CATCH    
		SET @error_num = ERROR_NUMBER()
		SET @error_msg = CONVERT(NVARCHAR, ERROR_NUMBER()) + ' ' + ERROR_MESSAGE()
		


		IF @error_num = 1205
		BEGIN
			RETURN
		END
		ELSE
		BEGIN
			RAISERROR(@error_msg,18,1)
			RETURN
		END
END CATCH

EXIT_LABEL:
END

GO
