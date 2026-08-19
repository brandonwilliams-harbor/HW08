USE [AAD] 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[usp_ww_itmset_edit_dimensions]
	@in_employee_id			NVARCHAR(10),
	@in_wh_id				NVARCHAR(10),		
	@out_sysshort			NVARCHAR(20)	OUTPUT,
	@out_deadlock_flag		INT				OUTPUT,
/*END OF COMMON INPUTS*/
	@in_item_number		NVARCHAR(30),
	@in_description		NVARCHAR(60),
	@in_ti				INT,
	@in_hi				INT,
	@in_class_id		NVARCHAR(10),
	@in_std_hand_qty	FLOAT,
	@in_debug			INT = 0,
	@in_mix             INT,
	@in_aerosol_level	TINYINT, --BEW 20221214
	@in_flammable 		TINYINT --BEW 20221214

AS
/*********************************************************************************************************************

  Object:	[usp_ww_itmset_edit_dimensions]
  Description: Webwise Report; update item attributes not specific by UOM
			   Executed on Edit Page 'Item Setup Master' [1737]

  Version	Date		Intials		repo	Notes
  -------	--------	-------		-----	------------------------------------------------
  1.0		20170407	TTU					Created
  2.0		20170719	SJD					Added allow mix flag edit 
  3.0		20221214	BEW-HWF				Added fields: aerosol_level and flammable to update, 
											New t_tran_log holding insert for flammable and aerosol chnages. 
											Commeneted above tran log insert. Handling with 113 transaction
  4.0		20230405	BEW-HWF				Added error handliung for Ti/Hi and qty per pallet. 
  5.0		20250917	BEW-HWF		HW04	Added update flag for BFC export.
  6.0		20260730	BEW-HWF		HW06	Added logic to auto fill standard pallet qty
  7.0		20260819	BEW-HWF		HW08	Added logic to allow for updates to be global 
********************************************Sample Call*****************************************************************
	EXEC [usp_ww_itmset_edit_dimensions]
		@in_wh_id				= '01',
		@out_sysshort			= NULL,
		@out_deadlock_flag		= NULL,
	/*END OF COMMON INPUTS*/
		@in_item_number		= 'FNFG00000',
		@in_description		= 'Item FNFG00000',
		@in_ti				= '8',
		@in_hi				= '3',
		@in_class_id	    = 'FG',
		@in_std_hand_qty    = '16',
		@in_debug			= NULL

***********************************************************************************************************************/

BEGIN
SET NOCOUNT ON; -- Always use NOCOUNT for All procedures

DECLARE @error_num		NVARCHAR(MAX),
		@error_msg		NVARCHAR(MAX),
		@employee_id	NVARCHAR(30),
		@previous_aerosol_level TINYINT,
		@previous_flammable TINYINT

BEGIN TRY--Put procedure in Try/Catch so deadlocks can be caught
	
	--Clear Deadlock Flag and other variables
	SELECT
		@out_sysshort = NULL,
		@out_deadlock_flag = 0
	--(3.0) Begin
	IF @in_aerosol_level IN (2,3) AND ISNULL(@in_flammable, 0) = 0 
	BEGIN 
		RAISERROR('IF Aerosol Level set to 2 or 3, Flammable must be YES',18,1)
		GOTO EXITLABEL
	END
	--(3.0) End
	--(4.0) Begin
	IF @in_ti = 0 OR @in_hi = 0 
	BEGIN
		RAISERROR('TI/HI must be greater than 0.',18,1)
		GOTO EXITLABEL
	END 
--6.0 Begin 
	--IF @in_std_hand_qty = 0 
	--BEGIN 
	--	RAISERROR('Standard Pallet Qty must be greater than 0.',18,1)
	--END
	SET @in_std_hand_qty = @in_ti * @in_hi 
--(6.0) End 	 
	--(4.0) End
	SELECT @employee_id = LEFT(ISNULL(dbo.usf_get_employee_from_ww_user(@in_employee_id, @in_wh_id),@in_employee_id),10)
	
	--BEW 20221216
	--get previous values for inserting diff tran type records that will be picked up by WMS IUOM int. 
	--tran type 113 triggers Item master export. 
	SELECT @previous_aerosol_level = ISNULL(itm.aerosol_level, 0),
			@previous_flammable = ISNULL(itm.flammable, 0) 
	FROM t_item_master itm WITH (NOLOCK)
	WHERE itm.wh_id = @in_wh_id 
		AND UPPER(itm.item_number) = UPPER(@in_item_number)

	--Update statements
	UPDATE t_item_master
	SET	ti				= @in_ti,
		hi				= @in_hi,
		--class_id		= @in_class_id,
		std_hand_qty	= @in_std_hand_qty,
		--ver_flag		= '1',
		allow_mix_flag  = @in_mix,
		aerosol_level	= ISNULL(@in_aerosol_level, 0),	--BEW 20221214
		flammable       = ISNULL(@in_flammable, 0), --BEW 20221214
		bfc_export_flag = 1 --(5.0) Set flag to send to BFC on next export.			
	WHERE --wh_id = @in_wh_id --7.0 Comment out 
		UPPER(item_number) = UPPER(@in_item_number)

--7.0 Begin 
	--these fields to be whse specific 
	UPDATE t_item_master 
	SET class_id = @in_class_id, 
		ver_flag = 1 
	WHERE wh_id = @in_wh_id --7.0 Comment out 
		AND UPPER(item_number) = UPPER(@in_item_number)
--7.0 End 

	UPDATE t_item_uom
	SET	std_hand_qty = @in_std_hand_qty
	WHERE --wh_id = @in_wh_id --7.0 Comment out 
		UPPER(item_number) = UPPER(@in_item_number)

	--Create transaction record
	INSERT INTO t_tran_log_holding(
		tran_type,
		[description],
		start_tran_date,
		start_tran_time,
		end_tran_date,
		end_tran_time,
		employee_id,
		wh_id,
		item_number,
		uom,
		tran_qty,
		generic_attribute_1,
		generic_attribute_2,
		generic_attribute_3,
		generic_attribute_4,
		generic_attribute_5,
		generic_attribute_7, --BEW 20221214
		generic_attribute_8, --BEW 20221214 
		generic_attribute_9, --BEW 20221219
		generic_attribute_10,--BEW 20221219 
		sys_device,
		calling_procedure)
	SELECT
		'113',
		'Item Setup Master Update',
		GETDATE(),
		GETDATE(),
		GETDATE(),
		GETDATE(),
		ISNULL(@employee_id,@in_employee_id),
		@in_wh_id,
		@in_item_number,
		purchase_uom,
		1,
		@in_description,
		@in_ti,
		@in_hi,
		@in_class_id,
		@in_std_hand_qty,
		ISNULL(@in_aerosol_level, 0), 	--BEW 20221214
		ISNULL(@in_flammable, 0),		--BEW 20221214
		ISNULL(@previous_aerosol_level, 0),	--BEW 20221219
		ISNULL(@previous_flammable, 0),		--BEW 20221219
		'WEBWISE',
		OBJECT_NAME(@@PROCID)
	FROM t_item_master WITH (NOLOCK)
	WHERE UPPER(item_number) = UPPER(@in_item_number)
		AND wh_id = @in_wh_id

	

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
