USE [AAD]
GO


SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


ALTER PROCEDURE [dbo].[usp_ww_sales_header_interface] 
        @in_ww_username		NVARCHAR(MAX), 
        @in_wh_id   NVARCHAR(30),
        @in_load_id NVARCHAR(60), 
		@in_order_number NVARCHAR(20) --2.0 
AS
/****************************************************************************
 Description: Report page # for SO Header int records

 Version    Date        Initials    Repo    Notes
 -------    --------    --------    ----    -------------------------------------
 1.0        20250130    BEW-HWF     HW01    Created
 2.0		--------	BEW-HWF		HW08	Added order_number variable for search page 
--Grant webwise exec scripts
GRANT EXECUTE ON [dbo].[usp_ww_sales_header_interface] TO AAD_USER, WA_USER

***********************Sample call**************************************
EXEC [dbo].[usp_ww_sales_header_interface] 'BEW', '%', '%', '%' 
************************************************************************/

BEGIN 
SET NOCOUNT ON;

DECLARE @error_num INT,
		@error_msg NVARCHAR(MAX)

BEGIN TRY--Put procedure in Try/Catch so deadlocks can be caught
	--Clear Deadlock Flag and other variables


SELECT sh.unique_id AS wms_import_id
		,sh.order_number
        ,sh.load_id 
		,(	SELECT COUNT(distinct line_number) 
			FROM t_stage_so_line_detail sl  WITH (NOLOCK) 
			WHERE sh.order_number = sl.order_number 
				AND sh.document_entry_number = sl.document_entry_number 
		 ) AS  line_count 
		,CASE WHEN ISNULL(sh.wms_processed, 0) = 0 THEN 'No' ELSE 'Yes' END AS wms_processed 
		,sh.wh_id
		,sh.document_entry_number
		,sh.import_id as entry_no 
		,CASE WHEN ISNULL(sh.receiver_processed, '1753-01-01 00:00:00.000') = '1753-01-01 00:00:00.000' THEN '' ELSE sh.receiver_processed END AS receiver_processed
		,sh.receiver_success
		,sh.reason_failed
		,sh.customer_code
		,sh.ship_to_name 
		,sh.order_date
		,sh.earliest_ship_date AS planned_ship_date 
		,sh.carrier 
		,sh.[stop]
FROM t_stage_so_header sh WITH (NOLOCK) 
WHERE (wh_id = @in_wh_id)
    AND (@in_load_id = '%' OR load_id LIKE UPPER(@in_load_id))
	AND (@in_order_number = '%' OR order_number LIKE UPPER(@in_order_number)) --2.0


END TRY
BEGIN CATCH
  
	SELECT 
		@error_num = ERROR_NUMBER(),
		@error_msg = CONVERT(NVARCHAR, ERROR_NUMBER())+' '+ERROR_MESSAGE()

	IF @@TRANCOUNT > 0
	BEGIN
		ROLLBACK TRAN
	END

	SELECT @error_msg = LEFT('SQL Error ' + @error_msg + ', line=' + CONVERT(VARCHAR(12), ERROR_LINE()) , 20)
	RAISERROR(@error_msg, 0, 1)


	BEGIN
		RAISERROR(@error_msg,18,1)
		RETURN
	END
END CATCH

EXITLABEL:
	
	RETURN

END


GO


