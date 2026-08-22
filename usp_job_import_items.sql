USE [AAD]
GO


SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO




ALTER PROCEDURE [dbo].[usp_job_import_items] 
	@debug					INT 
/*********************************************************************************************************************************
 Description: Imports item master, item uom, item upc records from NAV/BC Interface tables into WMS tables.

 Version	Date		Initials	Repo	Notes
 -------	--------	--------	-----	---------------------------------------------------------------------------
 1.0		20250306	BEW-HWF		HW01	Created 
 1.1 		20250319	BEW-HWF		HW01	Added logic for Nonstock types and UM Restrictions 
 2.0        20250418    BEW-HWF     HW02    Convert decimal to float. Large conversion_factors display as 2000 but stored as 1999.999999. 
 3.0		20250505	BEW-HWF		HW02	Corrected bug that resets ignore_for_replen flag during iuom imports.
 4.0        20250522	BEW-HWF     HW03    Added insert into TruckBuilder Item export page 
 5.0		20250917	BEW-HWF		HW04	Added update flag for BFC export. 
 5.1		20251001	BEW-HWF		H404	Added logic for Loc Status
 5.2		20251104	BEW-HWF		H404	Corrected bug with UOM Restriction logic and Non Sellable flag 
 5.3		20251120	BEW-HWF		HW04	Added logic to reset ver_flag = 0 when item is discontinued. Removed 4.0 and update t_item_master bfc_export_flaf instead 
 6.0		20251219	BEW-HWF		HW05	Added logic to update  prev_non_stock_type(new field), and ns_convert_stats (new field) on t_item_master. Added logic to ignore deletions when error handling uom and upc records.
 6.1		20260206	BEW-HWF		HW05	Added logic for inserting into t_interface_stats table. Corrected bug from 5.3 
 7.0		--------	BEW-HWF		HW08	Added logic to close any unprocessed records prior to pull from NAV 

 *******************************************Sample call**************************************************************************
--Find Items not stored in whole number due to conversion issue from decimal to float. 
    SELECT CAST(conversion_factor AS DECIMAL(38, 18)) AS full_precision_value --shows actual stored value 
        ,item_number
        ,conversion_factor 
        ,uom 
        ,non_sellable_flag
        ,wh_id 
    FROM t_item_uom 
    where cast(conversion_factor AS DECIMAL(38, 18)) % 1 <> 0
    ORDER BY item_number 

    EXEC usp_job_import_items @debug = 1 

**********************************************************************************************************************************/
AS 
BEGIN
SET NOCOUNT ON; -- Always use NOCOUNT for All procedures

BEGIN TRY

	DECLARE @sql					NVARCHAR(MAX)
			,@header_id_string		NVARCHAR(MAX)
			,@ready_to_process		NVARCHAR(2)
			,@receiver_processed	NVARCHAR(60)
			,@receiver_success		NVARCHAR(2)
			,@type					NVARCHAR(2) 
			,@blank					NVARCHAR(MAX)
			,@linked_server         NVARCHAR(100)  
			,@linked_database       NVARCHAR(100) 
			,@item_int_table_no		NVARCHAR(20)
			,@iuom_int_table_no		NVARCHAR(20) 
			,@iupc_int_table_no		NVARCHAR(20)
			,@item_master_count		INT
			,@item_uom_count		INT
			,@item_upc_count		INT
			,@item_exist_thresh		INT
			,@default_class			NVARCHAR(10) 
			,@match					INT
			,@int_unique_id			INT --6.1 
			,@int_rec_count 		INT --6.1  
			--,@debug int = 1 

--6.1 Begin 
	INSERT INTO t_interface_stats 
	(calling_procedure, start_date_time, [type])
	VALUES 
	('usp_job_import_items', GETDATE(), 'IMPORT')

	SELECT TOP 1 @int_unique_id = unique_id 
	FROM t_interface_stats WITH (NOLOCK) 
	WHERE calling_procedure = 'usp_job_import_items'
		AND ISNULL(end_date_time, '') = '' 
--6.1 End 

--7.0 Begin 
	--CLose out any records that are not processed prior to running 
	UPDATE t_stage_item_master 
	SET wms_processed = 1 
	WHERE wms_processed = 0 

	UPDATE t_stage_item_uom 
	SET wms_processed = 1 
	WHERE wms_processed = 0 

	UPDATE t_stage_item_upc 
	SET wms_processed = 1 
	WHERE wms_processed = 0 
--7.0 End 

	--Need to create temp tables for initial insert because data is not whs speicifc in NAV
	DECLARE @t_itm TABLE
		( 
			[entry_no] [int] ,
			[type] [int],
			[wms_processed] [int] ,
			[newer_version_flag] [int] ,
			[sender_last_update] [datetime] ,
			[receiver_processed] [datetime] ,
			[receiver_success] [tinyint] ,
			[reason_failed] [nvarchar](100) ,
			[item_number] [nvarchar](20) ,
			[description] [nvarchar](50) ,
			[base_uom] [nvarchar](10) ,
			[pallet_flag] [tinyint] ,
			[pallet_quantity] [int] ,
			[minimum_order_quantity] [int] ,
			[maximum_order_quantity] [int] ,
			[item_category_code] [nvarchar](10) ,
			[product_group_code] [nvarchar](10) ,
			[catch_weight] [tinyint] ,
			[code_date_type] [int] ,
			[code_date_days] [int] ,
			[purchase_uom] [nvarchar](10) ,
			[ti] [int],
			[hi] [int],
			[sales_uom] [nvarchar](10) ,
			[haz_code] [nvarchar](10) ,
			[reporting_uom] [nvarchar](10) ,
			[product_type] [nvarchar](10) ,
			[wms_description] [nvarchar](60),
			[lot_control] [nvarchar](1) ,
			[product_class] [nvarchar](10) ,
			[inv_posting_group] [nvarchar](10),
			[gs1_required] [tinyint] ,
			[gs1_audit_flag] [tinyint], 
			[non_stock_status] [tinyint],
			[non_stock_type] [TINYINT],
			[aerosol_level] [int] ,
			[flammable] [tinyint] ,
			[ftl_item] [tinyint] ,
			[wh_id] [nvarchar](10),
			[loc_ns_type] [nvarchar](30), --(1.1)
			[loc_status] [nvarchar](30) --(5.1)
		)

	DECLARE @t_uom TABLE 
		( 
			[entry_no] [int] ,
			[type] [int] ,
			[wms_processed] [int] ,
			[newer_version_flag] [int] ,
			[sender_last_update] [datetime] ,
			[receiver_processed] [datetime] NULL,
			[receiver_success] [tinyint] ,
			[reason_failed] [nvarchar](100) ,
			[item_number] [nvarchar](20) ,
			[uom] [nvarchar](10) ,
			[qty_per_uom] [decimal](38, 20) ,
			[length] [decimal](38, 20) ,
			[width] [decimal](38, 20) ,
			[height] [decimal](38, 20) ,
			[cube] [decimal](38, 20) ,
			[weight] [decimal](38, 20) ,
			[container] [tinyint] ,
			[retail_description] [nvarchar](50) ,
			[non_sellable] [tinyint] ,
			[item_not_exist] [tinyint] ,
			[wh_id] [nvarchar](10),
			[uom_restriction] [tinyint],
			[restricted_wh_id] [nvarchar](30) --(1.1)

		)

	DECLARE @t_upc TABLE 
		( 
			[entry_no] [int] ,
			[type] [int] ,
			[newer_version_flag] [int] ,
			[sender_last_update] [datetime] ,
			[receiver_processed] [datetime] ,
			[receiver_success] [tinyint] ,
			[reason_failed] [nvarchar](100) ,
			[item_number] [nvarchar](20) ,
			[uom] [nvarchar](10) ,
			[upc] [nvarchar](80) ,
			[item_not_exist] [tinyint] ,
			[wms_processed] [int] ,
			[wh_id] [nvarchar](10)
		)

	DECLARE @t_miss_item TABLE 
		( 
			item_number nvarchar(20),
			missing_wh_id nvarchar(10)
		) 
--Begin Linked Server  
    SELECT @linked_server = c1 
    FROM t_control WITH (NOLOCK)
    WHERE control_type = 'LINKED_SERVER'

    IF @@rowcount = 0 
    BEGIN
        INSERT INTO t_control (control_type, [description], c1)
        VALUES ('LINKED_SERVER', 'Name of Linked Server', 'NAV')  
    END 

    SELECT @linked_database = c1
    FROM t_control WITH (NOLOCK)
    WHERE control_type = 'LINKED_SERVER_DB'

    IF @@ROWCOUNT = 0 
    BEGIN 
        INSERT INTO t_control (control_type, [description], c1)
        VALUES ('LINKED_SERVER_DB', 'Name of Linked Server DB', 'Nav')
    END 
--End Linked Server 

--Begin Controls for Int table #'s
	SELECT @item_int_table_no = c1
	FROM t_control WITH (NOLOCK)
	WHERE control_type = 'ITM_INT_TBL_NO' 

	IF @@ROWCOUNT = 0
	BEGIN
		INSERT INTO t_control (control_type, [description], c1) 
		VALUES ('ITM_INT_TBL_NO', 'Table # for WMS Item Int', '50008') 
	END 

	SELECT @iuom_int_table_no = c1
	FROM t_control WITH (NOLOCK)
	WHERE control_type = 'IUOM_INT_TBL_NO'

	IF @@ROWCOUNT = 0
	BEGIN
		INSERT INTO t_control (control_type, [description], c1) 
		VALUES ('IUOM_INT_TBL_NO', 'Table # for WMS IUOM Int', '50009') 
	END 

	SELECT @iupc_int_table_no = c1
	FROM t_control WITH (NOLOCK)
	WHERE control_type = 'IUPC_INT_TBL_NO'

	IF @@ROWCOUNT = 0
	BEGIN
		INSERT INTO t_control (control_type, [description], c1) 
		VALUES ('IUPC_INT_TBL_NO', 'Table # for WMS xRef Int', '50107') 
	END 
--End controls for int table #s 
--Begin Default class
	SELECT @default_class = c1 
	FROM dbo.t_control WITH (NOLOCK)
	WHERE control_type = 'DEFAULTPUTCLASS'

	IF @@ROWCOUNT < 1 
	BEGIN
		INSERT INTO dbo.t_control
			(
				control_type,
				[description],
				next_value,
				config_display,
				allow_edit,
				c1,
				c2,
				f1
			)
		VALUES
			(   'DEFAULTPUTCLASS', -- control_type - nvarchar(20)
				'PUT CLASS for mapping item', -- description - nvarchar(30)
				NULL,   -- next_value - int
				NULL, -- config_display - nvarchar(15)
				NULL, -- allow_edit - nchar(1)
				N'DRY', -- c1 - nvarchar(30)
				NULL, -- c2 - nvarchar(30)
				NULL -- f1 - float
			)
		SET @default_class = 'DRY'
	END
--End Default Class 

	--declare all default values here 
	SET @ready_to_process = 1
	SET @receiver_processed = '1753-01-01 00:00:00.000'
	SET @receiver_success = 0 
	SET @type = 2 		
	SET @blank = ''
	SET @item_exist_thresh = 5 

/*******************************Step 1, Grab available item master, uom, upc record***********************/
	--grabbing item master records 
	SET @sql = '
		SELECT * 
		FROM OPENQUERY([' + @linked_server + '],

		''SELECT top 100 [Entry No_]
				,[Type]
				,[Sender Last Update]
				,[Receiver Processed]
				,[Receiver Success]
				,[Reason Failed]
				,[No_]
				,[Description]
				,[Base Unit of Measure]
				,[Pallet Flag]
				,[Pallet Quantity]
				,[Minimum Order Quantity]
				,[Maximum Order Quantity]
				,[Item Category Code]
				,[Product Group Code]
				,[Catch Weight]
				,[Code Date Type]
				,[Code Date Days]
				,[Purch_ Unit of Measure]
				,[TI]
				,[HI]
				,[Sales Unit of Measure]
				,[Hazardous Code]
				,[Reporting Unit of Measure]
				,[Product Type]
				,[WMS Description]
				,[Lot Control]
				,[Product Class]
				,[Invt Posting Group]
				,[GS1 Required]
				,[Non Stock Status]
				,0 --NS TYPE 
				,[Aerosol Level]
				,[Flammable]
				,[FTL Item]
				,0
				,0
				,NULL
				,[Loc NS Types] --(1.1)
				,[Loc Status] --(5.1)
			FROM  [' + @linked_database + '].[dbo].[HWF$WMS Item Interface] WITH (NOLOCK)
			WHERE [Receiver Success] = ''''' + @receiver_success + '''''	
				AND [Reason Failed] = ''''' + @blank + ''''' 
		'')'

		INSERT INTO @t_itm
			(
				[entry_no]
				,[type]  
				,[sender_last_update]
				,[receiver_processed]
				,[receiver_success]
				,[reason_failed]
				,[item_number]
				,[description]
				,[base_uom]
				,[pallet_flag]
				,[pallet_quantity]
				,[minimum_order_quantity]
				,[maximum_order_quantity]
				,[item_category_code]
				,[product_group_code]
				,[catch_weight]
				,[code_date_type]
				,[code_date_days]
				,[purchase_uom]
				,[ti]
				,[hi]
				,[sales_uom]
				,[haz_code]
				,[reporting_uom]
				,[product_type]
				,[wms_description]
				,[lot_control]
				,[product_class]
				,[inv_posting_group]
				,[gs1_required]
				,[non_stock_status]
				,[non_stock_type] --default to 0, update later 
				,[aerosol_level]
				,[flammable]
				,[ftl_item]
				,wms_processed
				,newer_version_flag
				,wh_id 
				,[loc_ns_type] --(1.1)
				,[loc_status] --(5.1)
			)

	EXEC sp_executesql @sql ; 

	SET @item_master_count = @@ROWCOUNT

	IF ISNULL(@item_master_count, 0) = 0 
	BEGIN
		PRINT 'No Item Master records to process'
	END 

	--6.1 	
	SET @int_rec_count = @item_master_count 


--(5.0) Begin 
	UPDATE itm 
	SET bfc_export_flag = 1 
	FROM t_item_master itm WITH (NOLOCK)
	INNER JOIN t_whse w WITH (NOLOCK) 
		ON itm.wh_id = w.wh_id 
		AND ISNULL(w.[status], 0) = 1 --Active whse
	INNER JOIN @t_itm stg 
		ON itm.item_number = stg.item_number 

	IF @debug = 1 
	BEGIN 
		SELECT 'BFC FLAGGED EXPORT ITEMS', itm.item_number, itm.wh_id, itm.bfc_export_flag, itm.[description]
		FROM t_item_master itm WITH (NOLOCK)
        INNER JOIN t_whse w WITH (NOLOCK) 
            ON itm.wh_id = w.wh_id 
            AND ISNULL(w.[status], 0) = 1 --Active whse
        INNER JOIN @t_itm stg 
            ON itm.item_number = stg.item_number 
        WHERE itm.bfc_export_flag = 1
	END 
--(5.0) End 

	--Insert record per warehouse 
	INSERT INTO t_stage_item_master
		(
			[entry_no]
			,[type]  
			,[sender_last_update]
			,[receiver_processed]
			,[receiver_success]
			,[reason_failed]
			,[item_number]
			,[description]
			,[base_uom]
			,[pallet_flag]
			,[pallet_quantity]
			,[minimum_order_quantity]
			,[maximum_order_quantity]
			,[item_category_code]
			,[product_group_code]
			,[catch_weight]
			,[code_date_type]
			,[code_date_days]
			,[purchase_uom]
			,[ti]
			,[hi]
			,[sales_uom]
			,[haz_code]
			,[reporting_uom]
			,[product_type]
			,[wms_description]
			,[lot_control]
			,[product_class]
			,[inv_posting_group]
			,[gs1_required]
			,[gs1_audit_flag] 
			,[non_stock_status]
			,non_stock_type 
			,[aerosol_level]
			,[flammable]
			,[ftl_item]
			,wms_processed
			,newer_version_flag
			,wh_id 
			,loc_ns_type --(1.1)
			,loc_status --(5.1) 
		)
	SELECT itm.[entry_no]
			,itm.[type]  
			,itm.[sender_last_update]
			,GETUTCDATE() --receiver_processed 
			,itm.[receiver_success]
			,itm.[reason_failed]
			,itm.[item_number]
			,itm.[description]
			,CASE WHEN ISNULL(itm.[base_uom], '') = '' THEN 'EA' ELSE itm.base_uom END 
			,itm.[pallet_flag]
			,itm.[pallet_quantity]
			,itm.[minimum_order_quantity]
			,itm.[maximum_order_quantity]
			,NULLIF(itm.[item_category_code], '') 
			,NULLIF(itm.[product_group_code], '') 
			,itm.[catch_weight]
			,itm.[code_date_type]
			,itm.[code_date_days]
			,itm.[purchase_uom]
			,itm.[ti]
			,itm.[hi]
			,itm.[sales_uom]
			,NULLIF(itm.[haz_code], '') 
			,itm.[reporting_uom]
			,NULLIF(itm.[product_type], '') 
			,REPLACE(REPLACE(REPLACE(REPLACE(REPLACE( --replaceing special characters that create xml errors 
				itm.wms_description,
				'à', 'a'),
				'è', 'e'),
				'ì', 'i'),
				'ò', 'o'),
				'ù', 'u')	 
			,CASE itm.lot_control WHEN 0 
					THEN CASE WHEN ISNULL(itm.code_date_type, '') <> '' THEN 'F' ELSE 'N' END --Date coded product must also be lot controlled
					WHEN 1 THEN 'F' 
			 ELSE 'S' END
			,NULLIF(itm.[product_class], '') 
			,NULLIF(itm.[inv_posting_group], '')
			,itm.[gs1_required]
			,CASE WHEN itm.[gs1_required] = 1 THEN 1 ELSE 0 END 
			,itm.[non_stock_status]
			,itm.non_stock_type 
			,itm.[aerosol_level]
			,itm.[flammable]
			,itm.[ftl_item]
			,itm.wms_processed
			,itm.newer_version_flag
			,w.wh_id 
			,itm.loc_ns_type --(1.1)
			,itm.loc_status --(5.1) 
	FROM @t_itm itm
	INNER JOIN t_whse w WITH (NOLOCK) --Join to create record per whse
		ON w.wh_id = w.wh_id
		AND ISNULL(w.[status], 0) = 1 

	IF @debug = 1
	BEGIN
		SELECT 'Item Master', * FROM t_stage_item_master (nolock) where wms_processed = 0 
	END 


	--Grab available uom records
	SET @sql = '
		SELECT * 
		FROM OPENQUERY([' + @linked_server + '],

		''SELECT [Entry No_]
				,[Type]
				,[Sender Last Update]
				,[Receiver Processed]
				,[Receiver Success]
				,[Reason Failed]
				,[Item No_]
				,[Code]
				,[Qty_ per Unit of Measure]
				,[Length]
				,[Width]
				,[Height]
				,[Cubage]
				,[Weight]
				,[Container]
				,[Retail Desc_]
				,[Non-Sellable]
				,0
				,0 
				,0
				,NULL 
				,0
				,[UM Restrictions] --(1.1) 
			FROM  [' + @linked_database + '].[dbo].[HWF$WMS IUOM Interface] WITH (NOLOCK)
			WHERE [Receiver Success] = ''''' + @receiver_success + '''''	
				AND [Reason Failed] = ''''' + @blank + ''''' 
		'')'

		INSERT @t_uom
			( 
				[entry_no]
				,[type]
				,[sender_last_update]
				,[receiver_processed]
				,[receiver_success]
				,[reason_failed]
				,[item_number]
				,[uom]
				,[qty_per_uom]
				,[length]
				,[width]
				,[height]
				,[cube]
				,[weight]
				,[container]
				,[retail_description]
				,[non_sellable]
				,wms_processed
				,newer_version_flag
				,item_not_exist
				,wh_id 
				,uom_restriction 
				,restricted_wh_id --(1.1)
			)
	EXEC sp_executesql @sql ; 

	SET @item_uom_count = @@ROWCOUNT

	IF ISNULL(@item_uom_count, 0) = 0 
	BEGIN
		PRINT 'No Item UOM records to process'
	END 

	--6.1 
	SET @int_rec_count = @item_master_count + @item_uom_count 

--(5.0) Begin 
	UPDATE itm 
	SET bfc_export_flag = 1 
	FROM t_item_master itm WITH (NOLOCK)
	INNER JOIN t_whse w WITH (NOLOCK) 
		ON itm.wh_id = w.wh_id 
		AND ISNULL(w.[status], 0) = 1 --Active whse
	INNER JOIN @t_uom stg 
		ON itm.item_number = stg.item_number 
		AND itm.wh_id = w.wh_id 

	IF @debug = 1 
	BEGIN 
		SELECT 'BFC FLAGGED EXPORT IUOMS', itm.item_number, itm.wh_id, itm.bfc_export_flag, itm.[description]
		FROM t_item_master itm WITH (NOLOCK)
        INNER JOIN t_whse w WITH (NOLOCK) 
            ON itm.wh_id = w.wh_id 
            AND ISNULL(w.[status], 0) = 1 --Active whse
        INNER JOIN @t_itm stg 
            ON itm.item_number = stg.item_number 
        WHERE itm.bfc_export_flag = 1
	END 
--(5.0) End 

	INSERT t_stage_item_uom
		( 
			[entry_no]
			,[type]
			,[sender_last_update]
			,[receiver_processed]
			,[receiver_success]
			,[reason_failed]
			,[item_number]
			,[uom]
			,[qty_per_uom]
			,[length]
			,[width]
			,[height]
			,[cube]
			,[weight]
			,[container]
			,[retail_description]
			,[non_sellable]
			,wms_processed
			,newer_version_flag
			,item_not_exist
			,wh_id 
			,[totable]
			,uom_restriction 
			,restricted_wh_id --(1.1)
		)

	SELECT 	uom.[entry_no]
			,uom.[type]
			,uom.[sender_last_update]
			,GETUTCDATE() --uom.[receiver_processed]
			,uom.[receiver_success]
			,uom.[reason_failed]
			,uom.[item_number]
			,uom.[uom]
			,uom.[qty_per_uom]--(2.0) 
			,uom.[length]
			,uom.[width]
			,uom.[height]
			,uom.[cube]
			,uom.[weight]
			,uom.[container]
			,uom.[retail_description]
			,uom.[non_sellable]
			,uom.wms_processed
			,uom.newer_version_flag
			,uom.item_not_exist
			,w.wh_id
			,CASE WHEN uom.[uom] = 'CS' THEN 'N'  ELSE 'Y'  END AS totable --If case then not totable 
			,0 -- CASE WHEN ISNULL(umr.[UM], '') = '' THEN 0 ELSE 1 END AS uom_restriction --(4.0)
			,restricted_wh_id --(1.1)
	FROM @t_uom uom 
	INNER JOIN t_whse w WITH (NOLOCK) --Join to create record per whse
		ON w.wh_id = w.wh_id
		AND ISNULL(w.[status], 0) = 1 


	IF @debug = 1
	BEGIN
		SELECT 'Item UOM', * FROM t_stage_item_uom (nolock) where wms_processed = 0 
	END 
--(4.0) Begin 

--(4.0) End 

	--Grab available upc records 
	SET @sql = '
		SELECT * 
		FROM OPENQUERY([' + @linked_server + '],

		''SELECT [Entry No_]
				,[Type]
				,[Sender Last Update]
				,[Receiver Processed]
				,[Receiver Success]
				,[Reason Failed]
				,[Item No_]
				,[Unit of Measure]
				,[Cross-Reference No_]
				,0
				,0
				,0
				,NULL
			FROM  [' + @linked_database + '].[dbo].[HWF$WMS Item xRef Interface] WITH (NOLOCK)
			WHERE [Receiver Success] = ''''' + @receiver_success + '''''	
				AND [Reason Failed] = ''''' + @blank + ''''' 
		'')'

		INSERT INTO @t_upc 
			( 
				[entry_no]
				,[type]
				,[sender_last_update]
				,[receiver_processed]
				,[receiver_success]
				,[reason_failed]
				,[item_number]
				,[uom]
				,[upc]
				,newer_version_flag 
				,wms_processed
				,item_not_exist
				,wh_id
			)
	EXEC sp_executesql @sql ; 

	SET @item_upc_count = @@ROWCOUNT

	IF ISNULL(@item_upc_count, 0) = 0 
	BEGIN
		PRINT 'No Item UPC records to process'
	END 

	--6.1 
	SET @int_rec_count = @int_rec_count + @item_uom_count 

	--6.1 Begin 
	IF ISNULL(@int_rec_count, 0) = 0 
	BEGIN 
		PRINT 'No Items, IUOMs, UPCs for Import'
		--Delete record in stats table if nothing to import 
		DELETE FROM t_interface_stats 
		WHERE unique_id = @int_unique_id 
	END
	--6.1 End 
	
	INSERT INTO t_stage_item_upc 
		( 
			[entry_no]
			,[type]
			,[sender_last_update]
			,[receiver_processed]
			,[receiver_success]
			,[reason_failed]
			,[item_number]
			,[uom]
			,[upc]
			,newer_version_flag
			,wms_processed
			,item_not_exist
			,wh_id
		)
	SELECT upc.[entry_no]
			,upc.[type]
			,upc.[sender_last_update]
			,GETUTCDATE() -- upc.[receiver_processed]
			,upc.[receiver_success]
			,upc.[reason_failed]
			,upc.[item_number]
			,upc.[uom]
			,upc.[upc]
			,upc.newer_version_flag 
			,upc.wms_processed 
			,upc.item_not_exist
			,w.wh_id
	FROM @t_upc upc 
	INNER JOIN t_whse w WITH (NOLOCK) --Join to create record per whse
		ON w.wh_id = w.wh_id
		AND ISNULL(w.[status], 0) = 1 

	IF @debug = 1
	BEGIN
		SELECT 'Item UPCs', * FROM t_stage_item_upc (nolock) where wms_processed = 0 
	END 


/******************************************End Step 1, grab records available**************************************************/

/******************************************Begin Step 2, Alter data for whse**************************************************
	--Create item master record for missing warehouse locations if imported UOM or UPC exists in one warehouse but not another.
	--NAV items are not warehouse specific. When adding new warehouses items may exist in one location but not another. 
	--Find record that exist in one warehouse but not another. 
 *****************************************************************************************************************************/
--Begin finding missing Item info
	--Missing from IUOM 
	INSERT INTO @t_miss_item 
	SELECT DISTINCT stg.item_number
		,stg.wh_id AS missing_wh_id
	FROM t_stage_item_uom stg WITH (NOLOCK)
	LEFT JOIN t_item_master itm WITH (NOLOCK)
		ON stg.item_number = itm.item_number
		AND stg.wh_id = itm.wh_id 
	WHERE itm.wh_id IS NULL 
		AND stg.wms_processed = 0
		AND EXISTS ( SELECT 1 --must exist in at least one warehosue 
					FROM t_item_master itm2 WITH (NOLOCK)
					WHERE stg.item_number = itm2.item_number 
					) 
	--Missing from UPC
	INSERT INTO @t_miss_item 
	SELECT DISTINCT stg.item_number
		,stg.wh_id AS missing_wh_id
	FROM t_stage_item_upc stg WITH (NOLOCK)
	LEFT JOIN t_item_master itm WITH (NOLOCK)
		ON stg.item_number = itm.item_number
		AND stg.wh_id = itm.wh_id 
	WHERE itm.wh_id IS NULL 
		AND stg.wms_processed = 0
		AND EXISTS ( SELECT 1 --must exist in at least one warehosue 
					FROM t_item_master itm2 WITH (NOLOCK)
					WHERE stg.item_number = itm2.item_number 
					) 
		AND NOT EXISTS ( SELECT 1 --does not already exists from UOM insert above. Eliminate duplicate inserts 
						 FROM @t_miss_item mi 
						 WHERE stg.item_number = mi.item_number
							AND stg.wh_id = mi.missing_wh_id 
					   ) 
	IF @debug = 1
	BEGIN 	
		SELECT 'Missing Items', * FROM @t_miss_item
	END

	IF EXISTS ( SELECT 1 FROM @t_miss_item ) 
	BEGIN
		INSERT INTO t_item_master 
			(
				[item_number]
				,[description]
				,[uom]
				,[inventory_type]
				,[shelf_life]
				,[alt_item_number]
				,[commodity_code]
				,[nafta_pref_criteria]
				,[nafta_producer]
				,[nafta_net_cost]
				,[price]
				,[std_hand_qty]
				,[std_qty_uom]
				,[inspection_code]
				,[serial_control]
				,[lot_control]
				,wh_id 
				,[reorder_point]
				,[reorder_qty]
				,[cycle_count_class]
				,[last_count_date]
				,[class_id]
				,[pick_location]
				,[stacking_seq]
				,[comment_flag]
				,[ver_flag]
				,[upc]
				,[unit_weight]
				,[tare_weight]
				,[haz_material]
				,[inv_cat]
				,[inv_class]
				,[unit_volume]
				,[nested_volume]
				,[xdock_profile_id]
				,[pick_put_id]
				,[length]
				,[width]
				,[height]
				,[sample_rate]
				,[compatibility_id]
				,[commodity_type_id]
				,[freight_class_id]
				,[audit_required]
				,[msds_url]
				,[expiration_date_control]
				,[ucc_company_prefix]
				,[attribute_collection_id]
				,[display_item_number]
				,[client_code]
				,[department]
				,[category_group]
				,[category_description]
				,[host_status]
				,[size]
				,[pack]
				,[variant_controlled_flag]
				,[sub_class_id]
				,[catch_weight_flag]
				,[purchase_uom]
				,[sales_uom]
				,[date_type]
				,[ti]
				,[hi]
				,[import_id]
				,[phonetic_description]
				,[pallet_flag]
				,[pallet_quantity]
				,[shelf_no]
				,[min_order_quantity]
				,[max_order_quantity]
				,[item_category_code]
				,[product_group_code]
				,[hazardous_code]
				,[product_type]
				,[product_class]
				,[posting_group]
				,[allow_mix_flag]
				,[report_uom]
				,[gs1_required_flag]
				,[gs1_audit_datetime]
				,[gs1_audit_flag]
				,[non_stock_type]
				,[net_weight_barcode]
				,[aerosol_level]
				,[flammable]
			)
		SELECT DISTINCT 
				tmi.[item_number]
				,MAX(itm.[description])
				,MAX(itm.[uom])
				,MAX(itm.[inventory_type])
				,MAX(itm.[shelf_life])
				,MAX(itm.[alt_item_number])
				,MAX(itm.[commodity_code])
				,MAX(itm.[nafta_pref_criteria])
				,MAX(itm.[nafta_producer])
				,MAX(itm.[nafta_net_cost])
				,MAX(itm.[price])
				,MAX(itm.[std_hand_qty])
				,MAX(itm.[std_qty_uom])
				,MAX(itm.[inspection_code])
				,MAX(itm.[serial_control])
				,MAX(itm.[lot_control])
				,tmi.missing_wh_id 
				,MAX(itm.[reorder_point])
				,MAX(itm.[reorder_qty])
				,MAX(itm.[cycle_count_class])
				,MAX(itm.[last_count_date])
				,MAX(itm.[class_id])
				,MAX(itm.[pick_location])
				,MAX(itm.[stacking_seq])
				,MAX(itm.[comment_flag])
				,MAX(itm.[ver_flag])
				,MAX(itm.[upc])
				,MAX(itm.[unit_weight])
				,MAX(itm.[tare_weight])
				,MAX(itm.[haz_material])
				,MAX(itm.[inv_cat])
				,MAX(itm.[inv_class])
				,MAX(itm.[unit_volume])
				,MAX(itm.[nested_volume])
				,MAX(itm.[xdock_profile_id])
				,MAX(itm.[pick_put_id])
				,MAX(itm.[length])
				,MAX(itm.[width])
				,MAX(itm.[height])
				,MAX(itm.[sample_rate])
				,MAX(itm.[compatibility_id])
				,MAX(itm.[commodity_type_id])
				,MAX(itm.[freight_class_id])
				,MAX(itm.[audit_required])
				,MAX(itm.[msds_url])
				,MAX(itm.[expiration_date_control])
				,MAX(itm.[ucc_company_prefix])
				,MAX(itm.[attribute_collection_id])
				,MAX(itm.[display_item_number])
				,tmi.missing_wh_id --client_code 
				,MAX(itm.[department])
				,MAX(itm.[category_group])
				,MAX(itm.[category_description])
				,MAX(itm.[host_status])
				,MAX(itm.[size])
				,MAX(itm.[pack])
				,MAX(itm.[variant_controlled_flag])
				,MAX(itm.[sub_class_id])
				,MAX(itm.[catch_weight_flag])
				,MAX(itm.[purchase_uom])
				,MAX(itm.[sales_uom])
				,MAX(itm.[date_type])
				,MAX(itm.[ti])
				,MAX(itm.[hi])
				,MAX(itm.[import_id])
				,MAX(itm.[phonetic_description])
				,MAX(itm.[pallet_flag])
				,MAX(itm.[pallet_quantity])
				,MAX(itm.[shelf_no])
				,MAX(itm.[min_order_quantity])
				,MAX(itm.[max_order_quantity])
				,MAX(itm.[item_category_code])
				,MAX(itm.[product_group_code])
				,MAX(itm.[hazardous_code])
				,MAX(itm.[product_type])
				,MAX(itm.[product_class])
				,MAX(itm.[posting_group])
				,MAX(itm.[allow_mix_flag])
				,MAX(itm.[report_uom])
				,MAX(itm.[gs1_required_flag])
				,MAX(itm.[gs1_audit_datetime])
				,MAX(itm.[gs1_audit_flag])
				,MAX(itm.[non_stock_type])
				,MAX(itm.[net_weight_barcode])
				,MAX(itm.[aerosol_level])
				,MAX(itm.[flammable])
		FROM t_item_master itm WITH (NOLOCK)
		INNER JOIN @t_miss_item tmi
			ON itm.item_number = tmi.item_number 
			AND itm.wh_id <> tmi.missing_wh_id 
		GROUP BY tmi.[item_number], tmi.missing_wh_id

	END 

--End missing items information 

--Begin Newer Version flags 
	--If two records for item in interface, mark newer version on oldest so we only process changes for newest version
	UPDATE itm  
	SET itm.newer_version_flag = 1 
	FROM t_stage_item_master itm 
	WHERE EXISTS 
			(	SELECT 1 
				FROM t_stage_item_master itm2 WITH (NOLOCK) 
				WHERE itm.item_number = itm2.item_number
						AND itm2.entry_no > itm.entry_no 
						AND itm2.wms_processed = 0 
			)
		AND itm.wms_processed = 0 
	
	UPDATE uom   
	SET uom.newer_version_flag = 1 
	FROM t_stage_item_uom uom 
	WHERE EXISTS 
			(	SELECT 1 
				FROM t_stage_item_uom uom2 WITH (NOLOCK) 
				WHERE uom.item_number = uom2.item_number
						AND uom.uom = uom2.uom 
						AND uom2.entry_no > uom.entry_no 
						AND uom2.wms_processed = 0 
			)
		AND uom.wms_processed = 0 

	UPDATE upc   
	SET upc.newer_version_flag = 1 
	FROM t_stage_item_upc upc  
	WHERE EXISTS 
			(	SELECT 1 
				FROM t_stage_item_upc upc2 WITH (NOLOCK) 
				WHERE upc.item_number = upc2.item_number
					AND upc.uom = upc2.uom 
					AND upc.upc = upc2.upc 
					AND upc2.entry_no > upc.entry_no 
					AND upc2.wms_processed = 0 
			)
		AND upc.wms_processed = 0 
--End Newer version flags

--(1.1) Begin
 --Begin NS Parse & Update
	;WITH CTE AS 
		(
			SELECT 
				CAST('<x>' + REPLACE(loc_ns_type, '|', '</x><x>') + '</x>' AS XML) AS xml_data
				,item_number
			FROM t_stage_item_master WITH (NOLOCK)
			WHERE wms_processed = 0
				AND [type] IN (0,1) --Insert, Modify 
				AND ISNULL(loc_ns_type, '') <> ''
				AND newer_version_flag = 0 

		)
		SELECT 
			LEFT(m.n.value('.', 'VARCHAR(100)'), CHARINDEX('-', m.n.value('.', 'VARCHAR(100)')) - 1) AS wh_id
			,RIGHT(m.n.value('.', 'VARCHAR(100)'), LEN(m.n.value('.', 'VARCHAR(100)')) - CHARINDEX('-', m.n.value('.', 'VARCHAR(100)'))) AS non_stock_type
			,item_number
		INTO #temp_nonstock
		FROM CTE
		CROSS APPLY xml_data.nodes('/x') AS m(n);

	UPDATE stg 
	SET stg.non_stock_type = tn.non_stock_type
	FROM t_stage_item_master stg 
	INNER JOIN #temp_nonstock tn 
		ON stg.wh_id = tn.wh_id 
		AND stg.item_number = tn.item_number 
	WHERE stg.wms_processed = 0
		AND stg.[type] IN (0,1) --Insert, Modify
		AND stg.newer_version_flag = 0 

--6.0 Begin 

	
	--IF non stock, eval existing non stock type and update fields if value do not match. and we have existing inventory and PO's to be received. 
	--IF no active inventory or nonstock po's to receive. Just update via merge statement below. 

	--nonstock to stock items 
	UPDATE itm 
	SET itm.prev_ns_type = itm.non_stock_type
		,itm.ns_convert_status =  1  --item is being transitioned from nonstock to stock 
		--,itm.ver_flag = 0 --reset ver_flag for warehouse to slot item  
	FROM t_item_master itm 
	INNER JOIN t_stage_item_master sim WITH (NOLOCK)
		ON itm.wh_id = sim.wh_id 
		AND itm.item_number = sim.item_number
	WHERE sim.wms_processed = 0  
		AND ISNULL(itm.non_stock_type, 0) > 0 --item already flagged as nonstock type 
		AND ISNULL(sim.non_stock_type, 0 ) = 0 
		-- AND (EXISTS (SELECT 1
		-- 			FROM t_stored_item sto WITH (NOLOCK) 
		-- 			INNER JOIN t_hu_master hum WITH (NOLOCK)
		-- 				ON sto.wh_id = hum.wh_id 
		-- 				AND sto.hu_id = hum.hu_id 
		-- 				AND hum.[type] = 'NS' 
		-- 			WHERE sto.wh_id = itm.wh_id
		-- 				AND sto.item_number = itm.item_number 
		-- 			)
		-- 	OR EXISTS 	(SELECT 1 
		-- 		    FROM t_po_master pom WITH (NOLOCK)
		-- 			INNER JOIN t_po_detail pod WITH (NOLOCK)
		-- 				ON pom.wh_id = pod.wh_id 
		-- 				AND pom.po_number = pod.po_number 
		-- 			WHERE pom.[status] = 'O' 
		-- 				AND pom.wh_id = itm.wh_id 
		-- 				AND pod.item_number = itm.item_number 
		-- 				AND ISNULL(pod.non_stock_type, 0) <> 0 
		-- 			) ) 

	--stock to nonstock items 
	UPDATE itm 
	SET itm.prev_ns_type = itm.non_stock_type
		,itm.ns_convert_status = 2  --item is being transitioned from stock to non-stock 
	FROM t_item_master itm 
	INNER JOIN t_stage_item_master sim WITH (NOLOCK)
		ON itm.wh_id = sim.wh_id 
		AND itm.item_number = sim.item_number
	WHERE sim.wms_processed = 0 
		AND ISNULL(sim.non_stock_type, 0) <> 0 
		AND ISNULL(itm.non_stock_type, 0) = 0 --item flagged as stock 
		-- AND (EXISTS (SELECT 1
		-- 			FROM t_stored_item sto WITH (NOLOCK) 
		-- 			INNER JOIN t_hu_master hum WITH (NOLOCK)
		-- 				ON sto.wh_id = hum.wh_id 
		-- 				AND sto.hu_id = hum.hu_id 
		-- 				AND hum.[type] = 'NS' 
		-- 			WHERE sto.wh_id = itm.wh_id
		-- 				AND sto.item_number = itm.item_number 
		-- 			)
		-- 	OR EXISTS 	(SELECT 1 
		-- 		    FROM t_po_master pom WITH (NOLOCK)
		-- 			INNER JOIN t_po_detail pod WITH (NOLOCK)
		-- 				ON pom.wh_id = pod.wh_id 
		-- 				AND pom.po_number = pod.po_number 
		-- 			WHERE pom.[status] = 'O' 
		-- 				AND pom.wh_id = itm.wh_id 
		-- 				AND pod.item_number = itm.item_number 
		-- 				AND ISNULL(pod.non_stock_type, 0) <> 0 
		-- 			) ) 
/* 6.1 Comment out below 
	--Reset ver_flag on uom 
	UPDATE uom 
	SET uom.ver_flag = 0 
	FROM t_item_uom uom 
	INNER JOIN t_stage_item_master si WITH (NOLOCK)
		ON uom.item_number = si.item_number 
		AND uom.wh_id = si.wh_id 
	INNER JOIN t_item_master itm WITH (NOLOCK)
		ON uom.wh_id = itm.wh_id 
		AND uom.item_number = itm.item_number 
	LEFT JOIN t_fwd_pick fwd WITH (NOLOCK) 
		ON uom.item_number = fwd.item_number
		AND uom.wh_id = fwd.wh_id 
	WHERE si.wms_processed = 0 
		AND ISNULL(si.non_stock_type, 0 ) = 0 
		AND ISNULL(itm.ns_convert_status, 0 ) = 1
		AND ISNULL(fwd.location_id, '') = '' --not slotted
		
	--reset itm ver_flag if no home location. 
	UPDATE itm 
	SET itm.ver_flag = 0 
	FROM t_item_master itm 
	INNER JOIN t_stage_item_master si WITH (NOLOCK)
		ON itm.item_number = si.item_number 
		AND itm.wh_id = si.wh_id
	INNER JOIN t_item_uom uom WITH (NOLOCK)
		ON si.wh_id = uom.wh_id 
		AND si.item_number = uom.item_number
	WHERE si.wms_processed = 0 
		AND ISNULL(si.non_stock_type, 0 ) = 0 
		AND ISNULL(uom.ver_flag, 0) = 0 
*/ 	

--6.0 End 

	--End NS Parse and Update
--(5.1) Begin
	--Begin Loc Status Parse & Update
	;WITH CTE AS 
		(
			SELECT 
				CAST('<x>' + REPLACE(loc_status, '|', '</x><x>') + '</x>' AS XML) AS xml_data
				,item_number
			FROM t_stage_item_master WITH (NOLOCK)
			WHERE wms_processed = 0
				AND [type] IN (0,1) --Insert, Modify 
				AND ISNULL(loc_status, '') <> ''
				AND newer_version_flag = 0 

		)
		SELECT 
			LEFT(m.n.value('.', 'VARCHAR(100)'), CHARINDEX('-', m.n.value('.', 'VARCHAR(100)')) - 1) AS wh_id
			,RIGHT(m.n.value('.', 'VARCHAR(100)'), LEN(m.n.value('.', 'VARCHAR(100)')) - CHARINDEX('-', m.n.value('.', 'VARCHAR(100)'))) AS loc_status
			,item_number
		INTO #temp_loc_status
		FROM CTE
		CROSS APPLY xml_data.nodes('/x') AS m(n);

	UPDATE stg 
	SET stg.host_status = ls.loc_status 
	FROM t_stage_item_master stg 
	INNER JOIN #temp_loc_status ls  
		ON stg.wh_id = ls.wh_id 
		AND stg.item_number = ls.item_number 
	WHERE stg.wms_processed = 0
		AND stg.[type] IN (0,1) --Insert, Modify
		AND stg.newer_version_flag = 0 
	--End Loc Status Parse & Update
--(5.1) End 
	--Begin UM Restriction Parse and Update
	;WITH CTE AS 
		(
    	SELECT 
        	CAST( '<x>' + REPLACE(restricted_wh_id, '|', '</x><x>') + '</x>' AS XML) AS xml_data
			,item_number
			,uom	
		FROM t_stage_item_uom WITH (NOLOCK)
		WHERE wms_processed = 0 
			AND [type] IN (0,1)
			AND ISNULL(restricted_wh_id, '') <> '' 
			AND newer_version_flag = 0 
		)
		SELECT 
    		m.n.value('.', 'VARCHAR(100)') AS wh_id
			,item_number
			,uom 
		INTO #temp_restriction
		FROM CTE
		CROSS APPLY xml_data.nodes('/x') AS m(n);

	UPDATE uom 
	SET uom.uom_restriction = 1 
		,uom.non_sellable = 1 --(5.2) 
	FROM t_stage_item_uom uom 
	INNER JOIN #temp_restriction tr 
		ON uom.wh_id = tr.wh_id
		AND uom.item_number = tr.item_number
		AND uom.uom = tr.uom 
	WHERE uom.wms_processed = 0
		AND uom.[type] IN (0,1) --Insert, Modify
		AND uom.newer_version_flag = 0 
	--End UM Restriction Pasre and Update
--(1.1) End 

--Begin Update item non stock type if 
	--TODO: Get with Les, instead of a flag where I have to go and scan the Item Location status table. 
			--Can we have a field added [Whs NS Type] = LDC3,RDC2 (LDC JIT), (RDC SUR) 
--End Non Stock updates

--Begin Default item class mapping 
	UPDATE itm 
	SET itm.class_id = map.class_id
	FROM t_stage_item_master itm 
	INNER JOIN t_item_class_map map WITH (NOLOCK)
		ON  ISNULL(map.product_class ,'')=	ISNULL(itm.product_class ,'')
		AND ISNULL(map.hazardous_code,'') = ISNULL(itm.haz_code,'')
		AND ISNULL(map.posting_group ,'')=	ISNULL(itm.inv_posting_group ,'')
		AND ISNULL(map.product_type,'') =	ISNULL(itm.product_type	 ,'')
		AND map.wh_id = itm.wh_id
		AND itm.wms_processed = 0 
	--Create default class_id if class_id not updated above 
	INSERT INTO t_item_class_map
		(	
			product_class 
			,hazardous_code
			,posting_group 
			,product_type	
			,class_id
			,wh_id
		)
	SELECT  itm.product_class 
		   ,itm.haz_code
		   ,itm.inv_posting_group 
		   ,itm.product_type	
		   ,@default_class
		   ,itm.wh_id
	FROM t_stage_item_master itm WITH (NOLOCK)
	LEFT OUTER JOIN t_item_class_map map WITH (NOLOCK)
		ON itm.wh_id = map.wh_id
		AND ISNULL(itm.product_class, '') = ISNULL(map.product_class,'')
		AND ISNULL(itm.inv_posting_group, '') = ISNULL(map.posting_group, '')
		AND ISNULL(itm.product_type, '') = ISNULL(map.product_type, '')
		AND ISNULL(itm.haz_code, '') = ISNULL(map.hazardous_code, '')
	WHERE itm.class_id IS NULL
		AND map.class_id IS NULL
		AND itm.wh_id IS NOT NULL
		AND itm.wms_processed = 0 
	GROUP BY
		itm.product_class 
		,itm.haz_code
		,itm.inv_posting_group 
		,itm.product_type	
		,itm.wh_id


--End Dafault item class mapping 
/******************************************Begin Step 2, Alter data for whse**************************************************/
	IF @debug = 1
	BEGIN
		SELECT 'Beginning Validation'
	END 
/******************************************Begin Step 3, Validation************************************************************/
--Begin Item master validation
	IF ISNULL(@item_master_count, 0) > 0 
	BEGIN	
		UPDATE t_stage_item_master
		SET reason_failed = 'Item Number cannot be blank'
		WHERE ISNULL(item_number, '') = ''
			AND wms_processed = 0 
			AND newer_version_flag = 0 --all newer version flagged items will be reported as successful imports. 

		UPDATE t_stage_item_master 
		SET reason_failed = 'Description and WMS Description cannot be blank'
		WHERE (ISNULL([description], '') = '' OR ISNULL(wms_description, '') = '') 
			AND wms_processed = 0 
			AND newer_version_flag = 0 

		--UPDATE t_stage_item_master 
		--SET reason_failed = 'If Non Stock Status flag set, non stock type must be set on Item Location Status'
		--WHERE non_stock_status = 1 
		--	and wms_processed = 0
		--	AND newer_version_flag = 0 
			--and need process to grab NS type if flag is set. 

		--Check that delete records can actually be deleted
		UPDATE t1
		SET reason_failed = 'Item cannot be deleted: present in other business processes'
		FROM t_stage_item_master  t1
		WHERE [type] = 2 --delete record 
			AND wms_processed = 0 
			AND (
				EXISTS (	SELECT 1 
							FROM t_asn_detail asn WITH (NOLOCK) 
							WHERE asn.item_number = t1.item_number
								AND asn.wh_id = t1.wh_id)
				OR EXISTS (	SELECT 1 FROM t_po_detail pod WITH (NOLOCK) 
							WHERE pod.item_number = t1.item_number
								AND pod.wh_id = t1.wh_id)
				OR EXISTS (	SELECT 1 FROM t_order_detail odt WITH (NOLOCK)
							WHERE odt.item_number = t1.item_number
								AND odt.wh_id = t1.wh_id)
				OR EXISTS (	SELECT 1 FROM t_stored_item sto WITH (NOLOCK)
							WHERE sto.item_number = t1.item_number
								AND sto.wh_id = t1.wh_id)
				OR EXISTS (	SELECT 1 FROM t_receipt rec WITH (NOLOCK)
							WHERE rec.item_number = t1.item_number
								AND rec.wh_id = t1.wh_id)
				OR EXISTS (	SELECT 1 FROM t_rma_detail rma WITH (NOLOCK)
							WHERE rma.item_number = t1.item_number
								AND rma.wh_id = t1.wh_id)
				OR EXISTS ( SELECT 1 FROM t_rtv_detail rtv WITH (NOLOCK)
							WHERE rtv.item_number = t1.item_number
								AND rtv.wh_id = t1.wh_id )
				--BEW Added below, but found that there was logic to delete fwd pick assignment for deletes in old import job 
				--OR EXISTS ( SELECT 1 FROM t_fwd_pick fp WITH (NOLOCK)
				--			WHERE fp.item_number = t1.item_number
				--				AND fp.wh_id = t1.wh_id)
				)
	END 
--End Item Master Validation 
	
--Begin UOM Validation 
	IF ISNULL(@item_uom_count, 0) > 0 
	BEGIN 				
		UPDATE t_stage_item_uom
		SET reason_failed = 'Item Number or Code cannot be blank'
		WHERE ISNULL(item_number, '') = ''
			AND ISNULL(uom, '') = ''
			AND wms_processed = 0 
			AND ISNULL(newer_version_flag, 0) = 0 

		UPDATE t_stage_item_uom
		SET reason_failed = 'Qty Per UM cannot be zero'
		WHERE ISNULL(qty_per_uom, 0) = 0 --conversion_factor 
			AND wms_processed = 0 
			AND ISNULL(newer_version_flag, 0) = 0 

--Begin UOM Item not exist 
		--if Item does not exist. Flag it so we can ignore, the job will attempt to pick up the item master record during the next cycle. 
		UPDATE uom
		SET uom.item_not_exist =  1 --acts as a count, if we run the item through the job x aount of times we will throw an error.
				,reason_failed = 'Item Does not Exist Error 1.Ignore until error 5' 
		FROM t_stage_item_uom uom 
		WHERE NOT EXISTS (  SELECT 1 
							FROM t_item_master itm WITH (NOLOCK)
							WHERE uom.wh_id = itm.wh_id	
								AND uom.item_number = itm.item_number
						 ) 
			AND uom.wms_processed = 0 
			AND ISNULL(uom.newer_version_flag, 0) = 0 
			AND ISNULL(uom.item_not_exist, 0) = 0 

		--if previous record has value in item_not_exist. Set value = value +1 
		;WITH cte AS 
			(	SELECT item_number, uom, MAX(unique_id) as max_id, ISNULL(MAX(item_not_exist),0) AS max_not_exist
				FROM t_stage_item_uom WITH (NOLOCK)
				WHERE wms_processed = 1 
					AND newer_version_flag = 0 
				GROUP BY item_number, uom 
			) 

		UPDATE uom 
		SET uom.item_not_exist = cte.max_not_exist  + 1 
			,uom.reason_failed = 'Item Does not Exist. Ignore until error 5' 
		FROM t_stage_item_uom uom 
		INNER JOIN cte 
			ON uom.item_number = cte.item_number 
			AND uom.uom = cte.uom 
			AND uom.unique_id > cte.max_id 
		WHERE ISNULL(uom.newer_version_flag, 0) = 0 
			AND uom.wms_processed = 0 
			AND NOT EXISTS (  SELECT 1 --Double check it doesn't exist because after presenting the final error. A user could have triggered an item master send in NAV. 
								FROM t_item_master itm WITH (NOLOCK)
								WHERE uom.wh_id = itm.wh_id	
									AND uom.item_number = itm.item_number
							) ; 
			--AND uom.item_number = '8970045'
		
		--Once item_not_exists = threshold. Generate an error for investigation in NAV. 
		UPDATE uom
		SET uom.reason_failed = 'Item does not exists in WMS. Please send Item Interface record'
		FROM t_stage_item_uom uom 
		WHERE uom.wms_processed = 0 
			AND ISNULL(uom.item_not_exist, 0) >= @item_exist_thresh 
			AND ISNULL(uom.newer_version_flag, 0) = 0 
			AND NOT EXISTS ( SELECT 1 
							 FROM t_item_master itm WITH (NOLOCK)
							 WHERE uom.item_number = itm.item_number 
							 	AND uom.wh_id = itm.wh_id 
							) 	
			AND uom.[type] <> 2 --6.0 Ignore deletions

		--Set as processed, we will only update NAV on the 5th job cycle if the item fails this many times 
		UPDATE t_stage_item_uom 
		SET wms_processed = 1
		WHERE item_not_exist BETWEEN 1 AND (@item_exist_thresh -1) 
--End UOM NOt exist 
		--Check that delete records can actually be deleted
		UPDATE t1
		SET reason_failed = 'Item UOM cannot be deleted: present in other business processes'
		FROM t_stage_item_uom  t1
		WHERE [type] = 2 --delete record 
			AND wms_processed = 0 
			AND (
				 EXISTS (	SELECT 1 FROM t_po_detail pod WITH (NOLOCK) 
							WHERE pod.item_number = t1.item_number
								AND pod.wh_id = t1.wh_id
								AND pod.order_uom = t1.uom)
				OR EXISTS (	SELECT 1 FROM t_order_detail odt WITH (NOLOCK)
							WHERE odt.item_number = t1.item_number
								AND odt.wh_id = t1.wh_id
								AND odt.order_uom = t1.uom)
				OR EXISTS (	SELECT 1 FROM t_receipt rec WITH (NOLOCK)
							WHERE rec.item_number = t1.item_number
								AND rec.wh_id = t1.wh_id
								AND rec.receipt_uom = t1.uom)
				OR EXISTS (	SELECT 1 FROM t_rma_detail rma WITH (NOLOCK)
							WHERE rma.item_number = t1.item_number
								AND rma.wh_id = t1.wh_id
								AND rma.uom = t1.uom)
				OR EXISTS ( SELECT 1 FROM t_rtv_detail rtv WITH (NOLOCK)
							WHERE rtv.item_number = t1.item_number
								AND rtv.wh_id = t1.wh_id
								AND rtv.uom = t1.uom)
				--BEW Added below, but found that there was logic to delete fwd pick assignment for deletes in old import job 
				--OR EXISTS ( SELECT 1 FROM t_fwd_pick fp WITH (NOLOCK)
				--			WHERE fp.item_number = t1.item_number
				--				AND fp.wh_id = t1.wh_id
				--				AND fp.uom = t1.uom) 
			)
	END 

--End Item Uom Validation

--Begin Item UPC Validation
	IF ISNULL(@item_upc_count, 0) > 0 
	BEGIN 			
		UPDATE t_stage_item_upc
		SET  reason_failed = 'Item Number, UM Code, or UPC cannot be blank'  
		WHERE wms_processed = 0 
			AND [type] IN (0,1)  
			AND ISNULL(newer_version_flag, 0) = 0 
			AND  ( ISNULL(upc,'') = ''  
				OR ISNULL(item_number,'') = '' 
				OR ISNULL(uom, '') = '' )  
	
		--if Item does not exist. Flag it so we can ignore, the job will attempt to pick up the item master record during the next cycle. 
		UPDATE upc
		SET upc.item_not_exist =  1 --acts as a count, if we run the item through the job x aount of times we will throw an error.
			,reason_failed = 'Item Does not Exist Error 1.Ignore until error 5' 
		FROM t_stage_item_upc upc 
		WHERE NOT EXISTS (  SELECT 1 
							FROM t_item_master itm WITH (NOLOCK)
							WHERE upc.wh_id = itm.wh_id	
								AND upc.item_number = itm.item_number
						 ) 
			AND upc.wms_processed = 0 
			AND ISNULL(upc.newer_version_flag, 0) = 0 
			AND ISNULL(upc.item_not_exist, 0) = 0 

		--if previous record has value in item_not_exist. Set value = value +1 
		;WITH cte AS 
			(	SELECT item_number, uom, CAST(upc AS NVARCHAR(80)) AS upc, MAX(unique_id) as max_id, ISNULL(MAX(item_not_exist),0) AS max_not_exist
				FROM t_stage_item_upc WITH (NOLOCK)
				WHERE wms_processed = 1 
					AND newer_version_flag = 0 
				GROUP BY item_number, uom, upc 
			) 

		UPDATE upc 
		SET upc.item_not_exist = cte.max_not_exist + 1   
			,reason_failed = 'Item Does not Exist. Ignore until error 5'
		FROM t_stage_item_upc upc 
		INNER JOIN cte 
			ON upc.item_number = cte.item_number 
			AND upc.uom = cte.uom
			AND upc.upc = cte.upc 
			AND upc.unique_id > cte.max_id 
		WHERE ISNULL(upc.newer_version_flag, 0) = 0 
			AND upc.wms_processed = 0 
			AND NOT EXISTS (	SELECT 1 --Double check it doesn't exist because after presenting the final error. A user could have triggered an item master send in NAV. 
								FROM t_item_master itm WITH (NOLOCK)
								WHERE upc.wh_id = itm.wh_id	
									AND upc.item_number = itm.item_number
							);  
		
		--Once item_not_exists = threshold. Generate an error for investigation in NAV. 
		UPDATE upc 
		SET upc.reason_failed = 'Item does not exists in WMS. Please send Item Interface record'
		FROM t_stage_item_upc upc 
		WHERE upc.wms_processed = 0 
			AND ISNULL(upc.item_not_exist, 0) >= @item_exist_thresh 
			AND ISNULL(upc.newer_version_flag, 0) = 0 
			AND NOT EXISTS ( SELECT 1 
							 FROM t_item_master itm WITH (NOLOCK)
							 WHERE upc.item_number = itm.item_number 
							 	AND upc.wh_id = itm.wh_id 
							) 
			AND upc.[type] <> 2 --6.0 Ignore deletions 

		--Set as processed, we will only update NAV on the 5th job cycle if the item fails this many times 
		UPDATE t_stage_item_upc 
		SET wms_processed = 1
		WHERE item_not_exist BETWEEN 1 AND (@item_exist_thresh -1) 
	END 
--End UPC Validation 

--If error for one warehouse location, apply the same error for other location codes.
	IF EXISTS ( SELECT 1 FROM t_stage_item_master WITH (NOLOCK) WHERE wms_processed = 0 AND reason_failed <> '' ) 
	BEGIN 
		UPDATE itm
		SET itm.reason_failed = itm2.reason_failed
		 FROM t_stage_item_master itm  
		INNER JOIN t_stage_item_master itm2
			ON itm.entry_no = itm2.entry_no 
		WHERE  itm.reason_failed = ''
			AND itm2.reason_failed <> ''
			AND itm.wms_processed = 0
			AND itm2.wms_processed = 0
	END 
	IF EXISTS ( SELECT 1 FROM t_stage_item_uom WITH (NOLOCK) WHERE wms_processed = 0 AND reason_failed <> '' ) 	
	BEGIN 
		UPDATE uom 
		SET uom.reason_failed = uom2.reason_failed
		 FROM t_stage_item_uom uom 
		INNER JOIN t_stage_item_uom uom2
			ON uom.entry_no = uom2.entry_no 
		WHERE  uom.reason_failed = ''
			AND uom2.reason_failed <> ''
			AND uom.wms_processed = 0
			AND uom2.wms_processed = 0
	END 
	IF EXISTS ( SELECT 1 FROM t_stage_item_upc WITH (NOLOCK) WHERE wms_processed = 0 AND reason_failed <> '' ) 	
	BEGIN 
		UPDATE upc 
		SET upc.reason_failed = upc2.reason_failed
		 FROM t_stage_item_upc upc 
		INNER JOIN t_stage_item_upc upc2
			ON upc.entry_no = upc2.entry_no 
		WHERE  upc.reason_failed = ''
			AND upc2.reason_failed <> ''
			AND upc.wms_processed = 0
			AND upc2.wms_processed = 0
	END 
							

	IF @debug = 1
	BEGIN 
		SELECT 'Item after validation', * FROM t_stage_item_master WITH (NOLOCK) WHERE wms_processed = 0 
		SELECT 'UOM after validation', CAST(qty_per_uom as float), * FROM t_stage_item_uom WITH (NOLOCK) WHERE wms_processed = 0 
		SELECT 'UPC after validation', * FROM t_stage_item_upc WITH (NOLOCK) WHERE wms_processed = 0 
	END 

/*****************************************End Step 3, Validation*****************************************/

/******************************************Begin Step 4, Insert into dest. tables********************************************/ 

--Begin Item Master records
	IF ISNULL(@item_master_count, 0) > 0 
	BEGIN 
		--Handled Item master deletes
		DELETE itm
		FROM t_item_master itm 
		INNER JOIN t_stage_item_master stg WITH (NOLOCK)
			ON itm.item_number = stg.item_number 
			AND itm.wh_id = stg.wh_id 
		WHERE stg.[type] = 2
			AND stg.wms_processed = 0
			AND stg.newer_version_flag = 0
			AND stg.reason_failed = ''

	--If we are deleting header, delete uom and upc records
	DELETE uom 
	FROM t_item_uom uom 
	INNER JOIN t_stage_item_master stg WITH (NOLOCK)
		ON uom.item_number = stg.item_number 
		AND uom.wh_id = stg.wh_id
	WHERE stg.[type] = 2 
		AND stg.newer_version_flag = 0 
		AND stg.reason_failed = '' 
		AND stg.wms_processed = 0 

	DELETE upc 
	FROM t_item_upc upc  
	INNER JOIN t_stage_item_master stg WITH (NOLOCK)
		ON upc.item_number = stg.item_number 
		AND upc.wh_id = stg.wh_id
	WHERE stg.[type] = 2 
		AND stg.newer_version_flag = 0 
		AND stg.reason_failed = '' 
		AND stg.wms_processed = 0 

		--Item master merge/update/insert 
		MERGE t_item_master AS dst 
		USING ( 
				SELECT stg.wh_id
						,stg.item_number
						,stg.wms_description --description
						,stg.wms_description as phonetic_description
						,stg.base_uom --verify 
						,stg.pallet_flag
						,stg.pallet_quantity
						,stg.minimum_order_quantity
						,stg.maximum_order_quantity
						,stg.item_category_code
						,stg.product_group_code
						,stg.catch_weight --catch_weright_flag
						,stg.code_date_type --date_type
						,stg.code_date_days --shel_life
						,stg.purchase_uom
						,stg.ti
						,stg.hi
						,stg.sales_uom
						,stg.haz_code
						,stg.product_type
						,stg.lot_control
						,stg.product_class
						,stg.inv_posting_group 
						,CASE WHEN stg.inv_posting_group IN('PCIG', 'PCGP') THEN 1 WHEN stg.class_id = 'CIG'  THEN 1 ELSE 0 END as variant_controlled_flag
						,stg.reporting_uom
						,stg.gs1_required
						,stg.gs1_audit_flag 
						,ISNULL(stg.class_id, @default_class) as class_id--class_id
						,stg.non_stock_type --(1.1)
						,stg.aerosol_level
						,stg.flammable
						,stg.ftl_item 
						,stg.host_status --(5.1)
				FROM t_stage_item_master stg WITH (NOLOCK)
				WHERE stg.wms_processed = 0
					AND stg.newer_version_flag = 0
					AND stg.[type] IN (0,1) --Insert, Modify 
					AND stg.reason_failed = '' 
			) AS src 
				ON dst.wh_id = src.wh_id
				AND dst.item_number = src.item_number 
			WHEN MATCHED THEN UPDATE 
			SET 
				dst.[description] =	src.[wms_description],		
				dst.phonetic_description = src.phonetic_description,
				dst.uom	= src.base_uom,				
				dst.pallet_flag	= src.pallet_flag,		
				dst.pallet_quantity	= src.pallet_quantity,			
				dst.min_order_quantity	= src.minimum_order_quantity,	
				dst.max_order_quantity = src.maximum_order_quantity,	
				dst.item_category_code = src.item_category_code,		
				dst.product_group_code = src.product_group_code,		
				dst.catch_weight_flag = src.catch_weight,		
				dst.expiration_date_control = CASE WHEN ISNULL(src.code_date_type, 0) = 0 THEN 0 ELSE 1 END,
				dst.date_type = CASE src.code_date_type WHEN 1 THEN 'R' WHEN 2 THEN 'P' WHEN 3 THEN 'S' WHEN 4 THEN 'E' END,
				dst.shelf_life = src.code_date_days,				
				dst.purchase_uom = src.purchase_uom,			
				dst.ti = src.ti,					
				dst.hi = src.hi,	
				dst.std_hand_qty = src.ti * dst.hi,
				dst.sales_uom = src.sales_uom,			
				dst.hazardous_code = src.haz_code,			
				dst.product_type = src.product_type,		
				dst.lot_control = src.lot_control,
				dst.product_class = src.product_class,
				dst.posting_group = src.inv_posting_group,
				dst.variant_controlled_flag = src.variant_controlled_flag,
				dst.report_uom = src.reporting_uom,
				dst.gs1_required_flag = src.gs1_required,
				dst.gs1_audit_flag = src.gs1_audit_flag, 
				dst.non_stock_type = src.non_stock_type, --(1.1)
				dst.aerosol_level = src.aerosol_level,	
				dst.flammable = src.flammable,			
				dst.ftl_item = src.ftl_item, 
				dst.host_status = src.host_status --(5.1)

			WHEN NOT MATCHED THEN INSERT
				( 
				wh_id,	
				item_number,			
				[description],			
				phonetic_description,	
				uom,					
				pallet_flag,			
				pallet_quantity,					
				min_order_quantity,		
				max_order_quantity,		
				item_category_code,		
				product_group_code,		
				catch_weight_flag,		
				expiration_date_control,
				date_type,
				shelf_life,				
				purchase_uom,			
				ti,						
				hi,						
				std_hand_qty,
				sales_uom,				
				hazardous_code,			
				product_type,		
				lot_control,
				product_class,
				posting_group,
				variant_controlled_flag,
				report_uom,
				class_id,
				gs1_required_flag,
				gs1_audit_flag, 
				non_stock_type, --(1.1)
				aerosol_level,
				flammable,	
				ftl_item,
				host_status --(5.1)
				) 
			VALUES 
				( 
					src.wh_id,	
					src.item_number,			
					src.[wms_description],			
					src.wms_description,	
					src.base_uom,					
					src.pallet_flag,			
					src.pallet_quantity,						
					src.minimum_order_quantity,		
					src.maximum_order_quantity,		
					src.item_category_code,		
					src.product_group_code,		
					src.catch_weight,		
					CASE WHEN ISNULL(src.code_date_type, 0) = 0 THEN 0 ELSE 1 END,
					CASE src.code_date_type WHEN 1 THEN 'R' WHEN 2 THEN 'P' WHEN 3 THEN 'S' WHEN 4 THEN 'E' END,
					src.code_date_days,				
					src.purchase_uom,			
					src.ti,						
					src.hi,			
					src.ti * src.hi,			
					src.sales_uom,				
					src.haz_code,			
					src.product_type,		
					src.lot_control,
					src.product_class,
					src.inv_posting_group,
					src.variant_controlled_flag,
					src.reporting_uom,
					src.class_id,
					src.gs1_required,
					src.gs1_audit_flag, 
					src.non_stock_type, --(1.1)
					src.aerosol_level,	
					src.flammable,		
					src.ftl_item,
					src.host_status --(5.1)  

				); 

	END 
--(5.3) Reset ver_flag on items if discontinued 
		--Just update everything each time we run this script. 
	UPDATE itm 
	SET ver_flag = 0 
	FROM t_item_master itm 
	INNER JOIN t_stage_item_master sim WITH (NOLOCK) --6.1
		ON itm.wh_id = sim.wh_id 
		AND itm.item_number = sim.item_number 
	WHERE ISNULL(itm.host_status, 0) = 2 
		AND ISNULL(itm.ver_flag, 0) <> 0 
		AND ISNULL(sim.wms_processed, 0) = 0 --6.1 

	UPDATE uom 
	SET uom.ver_flag = 0 
	FROM t_item_uom uom 
	INNER JOIN t_item_master itm WITH (NOLOCK)
		ON uom.wh_id = itm.wh_id 
		AND uom.item_number = itm.item_number 
	INNER JOIN t_stage_item_master sim WITH (NOLOCK) --6.1 
		ON itm.wh_id = sim.wh_id 
		AND itm.item_number = sim.item_number 
	WHERE ISNULL(itm.host_status, 0) = 2 
		AND ISNULL(itm.ver_flag, 0) <> 0 
		AND ISNULL(sim.wms_processed, 0) = 0 --6.1 
--(5.3) End

--End Item master records 
--Begin IUOM Records
	IF ISNULL(@item_uom_count, 0) > 0
	BEGIN 
		--Handle deletes first
		DELETE itm 
		FROM t_item_uom itm 
		INNER JOIN t_stage_item_uom stg
			ON itm.item_number = stg.item_number  
			AND itm.uom = stg.uom   
			AND itm.wh_id = stg.wh_id  
		 WHERE stg.[type] = 2  
			AND stg.reason_failed = ''
			AND stg.newer_version_flag = 0 
			AND stg.wms_processed = 0 

		--Ignore replens ignore flag for CIG Cases	
		UPDATE uom  
		SET ignore_for_replen_flag = CASE WHEN uom.uom = 'CS' AND ISNULL(itm.class_id, '') = 'CIG' THEN 1 ELSE ISNULL(uom.ignore_for_replen_flag, 0 ) END   --ELSE 0 END--(3.0) 
		FROM t_item_uom uom  
		INNER JOIN t_stage_item_uom stg WITH (NOLOCK)
			ON uom.item_number = uom.item_number  
			AND uom.wh_id = stg.wh_id  
			AND uom.uom = stg.uom  
		INNER JOIN t_item_master itm WITH (NOLOCK)  
			ON uom.item_number = itm.item_number  
			AND uom.wh_id = itm.wh_id  
		WHERE stg.wms_processed = 0 
			AND stg.newer_version_flag = 0 
			AND stg.reason_failed = ''

		--Set values on item master for each UOM  
		UPDATE itm  
		SET itm.[length] = w.[length],  
			itm.width = w.width,  
			itm.height = w.height,  
			itm.unit_volume = w.[cube],  
			itm.nested_volume = w.[cube]
		FROM t_item_master itm  
		INNER JOIN t_stage_item_uom w WITH (NOLOCK) 
			ON itm.item_number = w.item_number  
			AND itm.wh_id = w.wh_id  
		WHERE w.uom = 'EA'   
			AND w.[type] IN (0,1)
			AND w.wms_processed = 0
			AND w.newer_version_flag = 0 
			AND w.reason_failed = '' 

		--Create/Update UOM records  
		MERGE t_item_uom AS dst  
			USING ( SELECT 
						stg.item_number,    
						stg.uom,      
						CAST(ROUND(stg.qty_per_uom, 0) AS FLOAT) AS qty_per_uom, --(2.0) 
						stg.[length],      
						stg.width,      
						stg.height,      
						stg.[cube],    
						stg.[weight],     
						stg.container, --container_flag    
						stg.totable, --KNC 1/27/18  
						stg.retail_description,    
						stg.non_sellable,  
						stg.uom as uom_prompt,  
						stg.wh_id,
						stg.uom_restriction --(1.1)
					FROM t_stage_item_uom stg WITH (NOLOCK)  
					WHERE stg.wms_processed = 0
						AND stg.newer_version_flag = 0 
						AND stg.[type] IN (0,1)
						AND stg.reason_failed = ''
						AND stg.item_not_exist = 0 --item must exist 
					) AS src  
						ON dst.item_number = src.item_number  
						AND dst.wh_id = src.wh_id  
						AND dst.uom = src.uom  
			WHEN MATCHED THEN UPDATE  
				SET  
					dst.conversion_factor = CAST(ROUND(src.qty_per_uom, 0) AS FLOAT),  --(2.0) 
					dst.[length] = CASE src.[length] WHEN 0 THEN 1 ELSE src.[length] END,  
					dst.width  = CASE src.width WHEN 0 THEN 1 ELSE src.width END,  
					dst.height = CASE src.height WHEN 0 THEN 1 ELSE src.height END,  
					dst.unit_volume = src.[cube],  
					dst.uom_weight = src.[weight],  
					dst.container_flag = src.container,  
					--dst.totable = src.totable, --Do not update, if warehouse has item flagged as totable. That is source of truth
					dst.retail_desc = src.retail_description,  
					dst.non_sellable_flag = src.non_sellable,  
					dst.shippable_uom = CASE src.non_sellable WHEN 1 THEN 0 ELSE 1 END,
					dst.uom_restriction = src.uom_restriction  --(1.1)

			WHEN NOT MATCHED THEN INSERT  
				(  
					item_number,    
					uom,      
					conversion_factor,  
					[length],      
					width,      
					height,      
					unit_volume,    
					uom_weight,     
					container_flag,    
					totable,  
					retail_desc,    
					non_sellable_flag,  
					uom_prompt,  
					shippable_uom,  
					wh_id,
					uom_restriction --(1.1) 
				)  
			VALUES  
				(  
					src.item_number,  
					src.uom,  
					CAST(ROUND(src.qty_per_uom, 0) AS FLOAT),  --(2.0) 
					CASE src.[length] WHEN 0 THEN 1 ELSE src.[length] END,  
					CASE src.width WHEN 0 THEN 1 ELSE src.width END,  
					CASE src.height WHEN 0 THEN 1 ELSE src.height END,  
					src.[cube],  
					src.[weight],  
					src.container,  
					src.totable,   
					src.retail_description,  
					src.non_sellable,  
					src.uom,  
					CASE src.non_sellable WHEN 1 THEN 0 ELSE 1 END,  
					src.wh_id,
					src.uom_restriction --(1.1) 
				);
	END 
--End UOM Inserts/updates/deletes

--Begin UPC Inserts/updates/deletes
	IF ISNULL(@item_upc_count, 0) > 0 
	BEGIN
		
		--handle upc deletes first 
		 DELETE upc  
		 FROM t_item_upc upc 
		 INNER JOIN t_stage_item_upc stg WITH (NOLOCK)
			ON upc.item_number = stg.item_number  
			AND upc.upc = stg.upc   
			AND upc.wh_id = stg.wh_id  
		 WHERE stg.[type] = 2  
			AND stg.reason_failed = ''
			AND stg.wms_processed = 0
			AND stg.newer_version_flag = 0 

		 -- Create/Update UPC records  
		MERGE t_item_upc AS dst  
		USING ( SELECT  
					stg.item_number,  
					stg.upc,  
					stg.wh_id,  
					stg.uom,  
					GETDATE() as modified_datetime  
				FROM t_stage_item_upc stg WITH (NOLOCK)  
				WHERE stg.[type] IN (0,1)
					AND stg.wms_processed = 0
					AND stg.newer_version_flag = 0 
					AND stg.reason_failed = '' 
					AND stg.item_not_exist = 0 --Item must exist in t_item_master first
				GROUP BY  
					stg.item_number,  
					stg.upc,  
					stg.wh_id,  
					stg.uom  
			 ) AS src  
				ON dst.item_number = src.item_number  
				AND dst.upc = src.upc  
				AND dst.uom = src.uom  
				AND dst.wh_id = src.wh_id  
		WHEN MATCHED 
		THEN UPDATE  
			SET @match = 1,
			dst.modified_datetime = src.modified_datetime  
		WHEN NOT MATCHED 
		THEN INSERT  
				 (  
				  wh_id,  
				  item_number,  
				  upc,  
				  uom,  
				  modified_datetime  
				 )  
			VALUES  
				 (  
				  src.wh_id,  
				  src.item_number,  
				  src.upc,  
				  src.uom,  
				  GETDATE()  
				 );  
	END 
--End UPC inserts/updates/deletes 

/***********************************************End Step 4,  Insert into dest. tables*********************************************/

/***********************************************Begin step 5, Error Emails and Update NAV w/ results********************************************/
--Begin Error Emails 
	--Item Master errors
	IF EXISTS ( SELECT 1 FROM t_stage_item_master WITH (NOLOCK) WHERE wms_processed = 0 AND newer_version_flag = 0 and reason_failed <> '')
	BEGIN
		INSERT INTO [dbo].[t_email_q]
           (
				[source]
				,[tran_log_id]
				,[error_date]
				,[status]
				,[subject]
				,[message]
				,[address]
				,error
				,message_type
				,error_type
				,document_number
		   )
     SELECT
           OBJECT_NAME(@@PROCID)
           ,0
           ,GETDATE()
           ,'N'
		   ,'Item Import Error'
           ,CASE WHEN ISNULL(item_number, '') = '' THEN 'Item Header Error: Item Number cannot be blank' -- AAA 20190211
				ELSE 'Item Header Error for item: ' + item_number + ' error - ' + reason_failed END 
		   ,NULL
		   ,'Item Header Failure'
		   ,'IMPORT'
		   ,'ITEM'
		   ,item_number
	 FROM t_stage_item_master WITH (NOLOCK)
	 WHERE reason_failed <> ''
	   AND wms_processed = 0 
	   AND newer_version_flag = 0 
	END 

	--Item Uom Import Errors 
	IF EXISTS ( SELECT 1 FROM t_stage_item_uom WITH (NOLOCK) WHERE wms_processed = 0 AND newer_version_flag = 0 and reason_failed <> '')
	BEGIN
		INSERT INTO [dbo].[t_email_q]  
				(
					[source]  
					,[tran_log_id]  
					,[error_date]  
					,[status]  
					,[subject]  
					,[message]  
					,[address] 
					,error  
					,message_type  
					,error_type  
					,document_number
				)  
		 SELECT DISTINCT 
			   OBJECT_NAME(@@PROCID)  
			   ,0  
			   ,GETDATE()  
			   ,'N'  
			   ,'Item UOM Import Error'  
			   ,'Item Uom Error for item-uom: ' + item_number + '-' + uom + '. Error: ' + reason_failed   
			   ,NULL  
			   ,'Item Uom Failure'  
			   ,'IMPORT'  
			   ,'ITEM'  
			   ,item_number  
		FROM t_stage_item_uom WITH (NOLOCK) 
		WHERE reason_failed <> ''
			AND wms_processed = 0
			AND newer_version_flag = 0 
			AND item_not_exist <=  @item_exist_thresh 
	END 

	--Item UPC Errors
	IF EXISTS ( SELECT 1 FROM t_stage_item_upc WITH (NOLOCK) WHERE wms_processed = 0 AND newer_version_flag = 0 and reason_failed <> '')
	BEGIN
		INSERT INTO [dbo].[t_email_q]  
           (
				[source]  
				,[tran_log_id]  
				,[error_date]  
				,[status]  
				,[subject]  
				,[message]  
				,[address]  
				,error  
				,message_type  
				,error_type  
				,document_number
		)  
		SELECT DISTINCT 
		        OBJECT_NAME(@@PROCID)  
		        ,0  
		        ,GETDATE()  
		        ,'N'  
				,'Item UPC Import Error'  
		        ,'Item UPC Error for item-uom-upc: ' + item_number + '-' + uom + '-' + upc +'. Error: ' + reason_failed  
				,NULL  
				,'Item UPC Failure'  
				,'IMPORT'  
				,'UPC'  
				,item_number  
		FROM t_stage_item_upc WITH (NOLOCK) 
		WHERE reason_failed <> '' 
			AND wms_processed = 0
			AND newer_version_flag = 0 
			AND item_not_exist <= @item_exist_thresh 
	END 
--End Error emails 

--Begin Nav Updates	
	IF @debug = 1 
		BEGIN
			SELECT 'Item Master Count', @item_master_count 
			SELECT 'Item Uom Count', @item_uom_count 
			SELECT 'Item UPC Count', @item_upc_count 
		END 
	--Item Master records
	IF ISNULL(@item_master_count, 0) > 0 
	BEGIN
		SET @sql = '
			INSERT INTO OPENQUERY([' + @linked_server + '], 
				''SELECT 
					[Table ID],
					[Entry No_],
					[Create Date],
					[Last Eval Date],
					[Processed],
					[Error Reason],
					[Last Email Sent]
				FROM [' + @linked_database + '].[dbo].[HWF$WMS Update Log]''
			)
			SELECT  
				''' + @item_int_table_no + ''', --@item_table_no 
				entry_no,
				MAX(receiver_processed), --create_date 
					''' + CAST(@receiver_processed AS NVARCHAR(MAX)) + ''',
				0,
				MAX(reason_failed),
					''' + CAST(@receiver_processed AS NVARCHAR(MAX)) + ''' 
			FROM t_stage_item_master WITH (NOLOCK)
			WHERE wms_processed = 0
			GROUP BY entry_no
				;
		';
			IF @debug = 1
			BEGIN
				PRINT @sql 
			END 
		-- Execute the dynamic SQL
		EXEC(@sql);

		UPDATE t_stage_item_master 
		SET wms_processed = 1
			,receiver_success = CASE WHEN reason_failed = '' THEN 1 ELSE 0 END 
		WHERE wms_processed = 0
	END 
	--End Item records 
	--IUOM Records
	IF ISNULL(@item_uom_count, 0) > 0 
	BEGIN			

		SET @sql = '
			INSERT INTO OPENQUERY([' + @linked_server + '], 
				''SELECT  
					[Table ID],
					[Entry No_],
					[Create Date],
					[Last Eval Date],
					[Processed],
					[Error Reason],
					[Last Email Sent]
				FROM [' + @linked_database + '].[dbo].[HWF$WMS Update Log]''
			)
			SELECT 
				''' + @iuom_int_table_no + ''', --@iuom_table_no 
				entry_no,
				MAX(receiver_processed), --create_date 
					''' + CAST(@receiver_processed AS NVARCHAR(MAX)) + ''',
				0,
				MAX(reason_failed),
					''' + CAST(@receiver_processed AS NVARCHAR(MAX)) + ''' 
			FROM t_stage_item_uom WITH (NOLOCK)
			WHERE wms_processed = 0
			GROUP BY entry_no 
				;
		';
			IF @debug = 1
			BEGIN
				PRINT @sql 
			END 
		-- Execute the dynamic SQL
		EXEC(@sql);

		UPDATE t_stage_item_uom 
		SET wms_processed = 1
			,receiver_success = CASE WHEN reason_failed <> '' THEN 0 ELSE 1 END 
		WHERE wms_processed = 0
	END 
	--End IUOM
	--Begin UPC Records
	IF ISNULL(@item_upc_count, 0) > 0 
	BEGIN 

		SET @sql = '
			INSERT INTO OPENQUERY([' + @linked_server + '], 
				''SELECT 
					[Table ID],
					[Entry No_],
					[Create Date],
					[Last Eval Date],
					[Processed],
					[Error Reason],
					[Last Email Sent]
				FROM [' + @linked_database + '].[dbo].[HWF$WMS Update Log]''
			)
			SELECT  
				''' + @iupc_int_table_no + ''', --@iupc_table_no 
				entry_no,
				MAX(receiver_processed), --create_date 
					''' + CAST(@receiver_processed AS NVARCHAR(MAX)) + ''',
				0,
				MAX(reason_failed),
					''' + CAST(@receiver_processed AS NVARCHAR(MAX)) + ''' 
			FROM t_stage_item_upc WITH (NOLOCK)
			WHERE wms_processed = 0
			GROUP BY entry_no
				;
		';
			IF @debug = 1
			BEGIN
				PRINT @sql 
			END 
		-- Execute the dynamic SQL
		EXEC(@sql);

		UPDATE t_stage_item_upc 
		SET wms_processed = 1
			,receiver_success = CASE WHEN reason_failed <> '' THEN 0 ELSE 1 END 
		WHERE wms_processed = 0
	END 

--6.1 Begin 
	IF @int_rec_count > 0 
	BEGIN  
		UPDATE t_interface_stats 
		SET end_date_time = GETDATE() 
			,record_count = @int_rec_count 
		WHERE unique_id = @int_unique_id 
	END 

	UPDATE t_interface_stats 
	SET processing_seconds = CAST(DATEDIFF(MILLISECOND, start_date_time, end_date_time) / 1000.0 AS DECIMAL(10,3)) 
	WHERE unique_id = @int_unique_id 
--6.1 End 
	

--End Nav Updates 
/***********************************************End step 5, Error Emails and Update NAV w/ results********************************************/
END TRY
BEGIN CATCH
--EXITLABEL:
	
--	RETURN

--END
	PRINT 'caught error!!'

	SELECT ERROR_LINE() AS [error_line] 
		,ERROR_MESSAGE() AS [error_message]
		,ERROR_NUMBER() AS [error_number]


END CATCH

END 



GO


