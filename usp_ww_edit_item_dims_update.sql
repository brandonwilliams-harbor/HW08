
USE [AAD] 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [usp_ww_edit_item_dims_update]
	@in_ww_username 		NVARCHAR(MAX), --'~WW_USERNAME~',
	@in_wh_id				NVARCHAR(10),
	@in_item_number			NVARCHAR(30), 
    @in_item_uom            NVARCHAR(10),
    @in_length              FLOAT, 
    @in_width               FLOAT, 
    @in_height              FLOAT, 
    @in_uom_weight          FLOAT, 
    @in_class_id            NVARCHAR(10), --T_ITEM_MASTEr 
    @in_totable             NVARCHAR(1) 
AS
BEGIN
SET NOCOUNT ON;


/****************************************************************************************************************************************************************************************
  Description: Webwise inline edit for page #1938, Edit Item Dimensions  

  Version	Date		Intials		repo	Notes
  -------	--------	-------		-----	------------------------------------------------
  1.0		20260819		BEW-WF		HW08	Created

*****************************************Sample call***************************************************************************
EXEC [usp_ww_edit_item_dims_update]
GRANT EXEC ON [usp_ww_edit_item_dims_update] TO AAD_USER, WA_USER 

*****************************************************************************************************************************************************************************************/


BEGIN TRY 
	DECLARE @error_num			INT,
			@error_msg			NVARCHAR(MAX)

--Begin Error handling 
DEClARE @max_length		INT
		,@max_height	INT
		,@max_width		INT
--find max dims from control
--ISNULL value default to 500 
	SELECT @max_length = ( SELECT CAST(ISNULL(c1, 500) as INT) 
						FROM t_control WITH (NOLOCK) 
						WHERE control_type = 'DIM_LEN_MAX' ) 
	SELECT @max_height = ( SELECT CAST(ISNULL(c1, 500) as INT) 
						FROM t_control WITH (NOLOCK) 
						WHERE control_type = 'DIM_HEIGHT_MAX' ) 
	SELECT @max_width = ( SELECT CAST(ISNULL(c1, 500) as INT) 
						FROM t_control WITH (NOLOCK) 
						WHERE control_type = 'DIM_WID_MAX' )
	
	IF @in_length > @max_length			 
	BEGIN
		RAISERROR('Entered Length greater than system max.' , 16,1)
		GOTO EXITLABEL
	END 
	IF @in_height > @max_height
	BEGIN
		RAISERROR('Entered Height greater than system max.',16,1) 
		GOTO EXITLABEL
	END 
	IF @in_width > @max_width
	BEGIN
		RAISERROR('Entered Width greater than system max.',16,1)
		GOTO EXITLABEL
	END 

	IF @in_length <= 0 
	BEGIN 
		RAISERROR('Entered Length must be greater than 0.',16,1)
		GOTO EXITLABEL
	END
	IF @in_width <= 0 
	BEGIN 
		RAISERROR('Entered Width must be greater than 0.',16,1)
		GOTO EXITLABEL
	END
	IF @in_height <= 0 
	BEGIN 
		RAISERROR('Entered Height must be greater than 0.',16,1)
		GOTO EXITLABEL
	END
	IF @in_uom_weight <= 0 
	BEGIN 
		RAISERROR('Entered Weight must be greater than 0.',16,1)
		GOTO EXITLABEL
	END
	IF @in_uom_weight > 999 AND @in_item_uom <> 'PL' 
	BEGIN 
		RAISERROR('Entered Weight too high.',16,1) 
	END 
--End error handling 

--Global updates 
    UPDATE uom 
    SET uom.[length] = @in_length 
        ,uom.width = @in_width
        ,uom.height = @in_height 
        ,uom.uom_weight = @in_uom_weight
    FROM t_item_uom uom 
    WHERE uom.item_number = @in_item_number 
        AND uom.uom = @in_item_uom 

--whse specific updates
    UPDATE uom 
    SET uom.[totable] = @in_totable
    FROM t_item_uom uom 
    WHERE uom.item_number = @in_item_number 
        AND uom.wh_id = @in_wh_id 
        AND uom.uom = @in_item_uom 

    UPDATE t_item_master 
    SET class_id = @in_class_id 
    WHERE wh_id = @in_wh_id 
        AND item_number = @in_item_number 

END TRY
BEGIN CATCH
  
	SELECT 
		--@error_num = ERROR_NUMBER(),
		--@error_msg = CONVERT(NVARCHAR, ERROR_NUMBER())+' '+ERROR_MESSAGE()
		@error_msg = ERROR_MESSAGE()

	IF @@TRANCOUNT > 0
	--BEGIN
		ROLLBACK TRAN
	--END

	--SELECT @out_sysshort = LEFT('SQL Error ' + @error_num , 20)
	--RAISERROR(@error_msg, 0, 1)

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

EXITLABEL:


	RETURN

END
