
USE [AAD] 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [usp_ww_edit_item_dims]
	@in_ww_username 		NVARCHAR(MAX), --'~WW_USERNAME~',
	@in_wh_id				NVARCHAR(10),
	@in_item_number			NVARCHAR(30), 
    @in_description         NVARCHAR(60), 
    @in_item_status         NVARCHAR(3) 

AS
BEGIN
SET NOCOUNT ON;


/****************************************************************************************************************************************************************************************
  Description: Webwise edit page/report page for editing item dims. page # 1938 

  Version	Date		Intials		repo	Notes
  -------	--------	-------		-----	------------------------------------------------
  1.0		20260819		BEW-WF		HW08	Created

*****************************************Sample call***************************************************************************
EXEC usp_ww_edit_item_dims '100353', 'LDC', '0300303', '%', '%' 
GRANT EXEC ON usp_ww_edit_item_dims TO AAD_USER, WA_USER 

*****************************************************************************************************************************************************************************************/


BEGIN TRY 
	DECLARE @error_num			INT,
			@error_msg			NVARCHAR(MAX)


		SELECT uom.wh_id 
				,uom.item_number 
				,itm.[description] 
				,lu.[description] AS item_status 
				,uom.uom 
				,CASE WHEN ISNULL(uom.shippable_uom, 0) = 0 THEN 'NO' ELSE 'YES' END AS shippable_uom  
				,fwd.location_id as pick_location 
				,uom.conversion_factor 
				,uom.[length]
				,uom.width 
				,uom.height
				,uom.[uom_weight]
				,itm.class_id 
				,uom.[totable] 
				,CASE WHEN ISNULL(uom.ver_flag, 0) = 0 THEN 'NO' ELSE 'YES' END as ver_flag  
		FROM t_item_uom uom WITH (NOLOCK)
		INNER JOIN t_item_master itm WITH (NOLOCK)
			ON uom.wh_id = itm.wh_id
			AND uom.item_number = itm.item_number 
		LEFT JOIN t_lookup lu WITH (NOLOCK)
			ON lu.[source] = 't_item_master' 
			AND lu.lookup_type = 'HOSTSTATUS' 
			AND ISNULL(itm.host_status, 0) = lu.[text] 
		LEFT JOIN t_fwd_pick fwd WITH (NOLOCK)
			ON uom.wh_id = fwd.wh_id
			AND uom.item_number = fwd.item_number 
			AND uom.uom = fwd.uom 
		WHERE uom.wh_id = @in_wh_id 
			AND (@in_item_number = '%' 
				OR uom.item_number LIKE @in_item_number) 
			AND (@in_description = '%' 
				OR itm.[description] LIKE @in_description)
			AND (@in_item_status = '%'
				OR ISNULL(itm.host_status, 0) = @in_item_status)


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