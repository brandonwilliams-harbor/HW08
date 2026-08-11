USE [AAD] 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



ALTER PROCEDURE [dbo].[usp_ww_load_management_ship_confirm]
	@in_ww_username		NVARCHAR(MAX),
	@in_wh_id			NVARCHAR(10),
	@in_load            NVARCHAR(30),
	@in_seal            NVARCHAR(MAX),
	@in_trailer         NVARCHAR(50) 

AS
BEGIN
SET NOCOUNT ON;
/****************************************************************************************

  Object: [usp_ww_load_management_ship_confirm]
  Description:	HJ One Edit ship load confirmation, 

ChangeLog:
 Version	Date		Intials		Repo	Notes
  -------	--------	-------		-----	------------------------------------------------
  1.0		201700327	SJD					Created
  2.0		20170612	AMO					Fixed issue with ship confirm tran log insert
  3.0		20180313	KNC					Added check to confirm load not already shipped if so fail
  4.0		20220705	BEW-HWF     		Updated Insert into t_pod_queue for considering Will Call Orders 
  5.0		20220728	BEW-HWF				Added logic to ignore Will Call carriers for shipping route if items/pallets loaded. reates POD/Descartes load record
  6.0		20221229	BEW-HWF				Added logic to only set tote_count_flag on t_order if the customer has multiple orders for same stop on route.
  7.0		20240102	BEW-HWF				Added logic to ignore insert into t_pod_queue if load already exists in table
  8.0		20240724	BEW-HWF				Added logic to remove insert of TSF (Transfer) Orders into t_pod_queue 
  9.0		........	BEW-HWF		HW08	Added logic to insert tobacco counts into t_pod_shipments 
*********************************Sample Call************************************************


********************************************************************************************/
BEGIN TRY
	DECLARE @error_num			INT
			,@error_msg			NVARCHAR(MAX)
			,@shipment_number	NVARCHAR(30)
			,@employee			NVARCHAR(30)
			,@carrier			NVARCHAR(30) --BEW 20220728
			,@wc_door_loc		NVARCHAR(50) --BEW 20220729 

	--BEW 20221229 Begin
	IF OBJECT_ID('tempdb..#order_data') IS NOT NULL 
	BEGIN 
		DROP TABLE #order_data
	END 

	CREATE TABLE #order_data (
		stop_id				INT
		,ship_to_addr1		NVARCHAR(50)
		,ship_to_city		NVARCHAR(30)
		,ship_to_state		NVARCHAR(3)
		,ship_to_zip		NVARCHAR(12) 
		,order_number		NVARCHAR(30)
		,wh_id				NVARCHAR(10)
		,tote_count_flag	TINYINT	DEFAULT(0) 
		,stop_rank			TINYINT 
		) 

	INSERT INTO #order_data 
	SELECT  stop_id			
		   ,ship_to_addr1		
		   ,ship_to_city		
		   ,ship_to_state		
		   ,ship_to_zip
		   ,MAX(order_number) --max will only grab one order if customer has multiple for same stop 
		   ,wh_id 
		   ,1 --tote_count_flag 
		   ,ROW_NUMBER() OVER ( PARTITION BY
				 					ship_to_addr1		
									,ship_to_city		
									,ship_to_state		
									,ship_to_zip
								ORDER BY stop_id DESC ) AS stop_rank 
	FROM t_order WITH (NOLOCK)
	WHERE load_id = @in_load
		AND wh_id = @in_wh_id 
	GROUP BY  stop_id, ship_to_addr1, ship_to_city, ship_to_state, ship_to_zip, wh_id  
	--BEW 20221229 End

	--set carrier id for error handling below
	SELECT TOP 1 @carrier = ord.carrier
	FROM t_order ord WITH (NOLOCK)
	WHERE ord.load_id = @in_load

	IF ISNULL(RIGHT(@carrier,2),'') <> 'WC' --BEW, ignore if Will Call 
	BEGIN 
		IF EXISTS (
			SELECT 1
			FROM t_pick_detail pkd WITH (NOLOCK)
			LEFT OUTER JOIN t_hu_master hum WITH (NOLOCK)
				ON pkd.container_id = hum.hu_id
				AND pkd.wh_id = hum.wh_id
			WHERE pkd.load_id = @in_load
				AND pkd.wh_id = @in_wh_id
				AND NOT(pkd.picked_quantity = 0 AND pkd.[status] IN ('SHORTED', 'UNPICKED'))
				AND pkd.[status] <> 'LOADED'
				AND ISNULL(hum.[type], 'SO') <> 'LO' )
		BEGIN
			RAISERROR('NOT FULLY LOADED',18,1)
			GOTO EXIT_LABEL
		END
	END

	--KNC 3/13/18 Added check to confirm load not already shipped if so fail
	IF EXISTS ( 
		SELECT 1
		FROM t_pick_detail pkd WITH (NOLOCK)
		LEFT OUTER JOIN t_hu_master hum WITH (NOLOCK)
			ON pkd.container_id = hum.hu_id
			AND pkd.wh_id = hum.wh_id
		WHERE pkd.load_id = @in_load
			AND pkd.wh_id = @in_wh_id
			AND pkd.[status] = 'SHIPPED')
	BEGIN
		RAISERROR('LOAD ALREADY SHIPPED',18,1)
		GOTO EXIT_LABEL
	END

	SELECT @employee = dbo.usf_get_employee_from_ww_user(@in_ww_username, @in_wh_id)

	SELECT @shipment_number = shipment_number
	FROM t_shipment_master sm WITH (NOLOCK)
	INNER JOIN t_load_master lm WITH (NOLOCK)
		ON sm.load_master_id = lm.load_master_id
	WHERE lm.wh_id = @in_wh_id
		AND lm.load_id = @in_load

	IF ISNULL(@shipment_number, '') = ''
	BEGIN
		INSERT INTO t_shipment_master
			([wh_id]
			,[load_master_id]
			,[status]
			,[created_date]
			,[shipped_date])
		 SELECT
			@in_wh_id,
			load_master_id,
			'S',
			GETDATE(),
			GETDATE()
		FROM t_load_master WITH (NOLOCK)
		WHERE load_id = @in_load
			AND wh_id = @in_wh_id
	
		SET @shipment_number = CONVERT(VARCHAR(12), @@IDENTITY)
	END

	--If the load has not been invoiced 
	IF EXISTS (SELECT 8 FROM t_load_master WITH (NOLOCK) WHERE load_id = @in_load AND wh_id = @in_wh_id AND ISNULL(invoiced_flag,0) = 0 )
	BEGIN
		
		EXEC usp_ww_load_management_invoice_confirm
			@in_ww_username,
			@in_wh_id,
			@in_load,
			@in_trailer
	END
	--BEW 20220729, If Will Call route,set t_hu_master type = LO (loaded). Update location to default will call door location
	IF ISNULL(RIGHT(@carrier,2),'') = 'WC'
	BEGIN 
		--SET door location for WC if not set
		SELECT @wc_door_loc = COALESCE(lom.door_loc, wc.c1, 'DOOR001') 
		FROM t_load_master lom WITH (NOLOCK)
		LEFT JOIN t_whse_control wc WITH (NOLOCK)
			ON wc.wh_id = lom.wh_id
		WHERE lom.load_id = @in_load
			AND lom.wh_id = @in_wh_id
			AND wc.control_type = 'WC_DEFAULT_DOOR'

		UPDATE t_hu_master 
		SET type = 'LO'
			,location_id = @wc_door_loc
		WHERE load_id = @in_load
			AND wh_id = @in_wh_id 
			AND [type] <> 'LO' --not already loaded
		--BEW, updated so t_stored_item_shipped has correct door location
		UPDATE sto
		SET sto.location_id = @wc_door_loc 
		FROM t_stored_item sto
		INNER JOIN t_hu_master hum 
			ON sto.hu_id = hum.hu_id
			AND sto.wh_id = hum.wh_id
		WHERE hum.load_id = @in_load
			AND hum.wh_id = @in_wh_id
			AND hum.[type] <> 'LO' --not already loaded
			
	END


	BEGIN TRAN

	INSERT INTO t_hu_master_shipped
		(hu_id						
		,[type]
		,control_number
		,location_id
		,subtype
		,[status]
		,fifo_date
		,wh_id
		,load_position
		,haz_material
		,load_id
		,load_seq
		,ver_flag
		,[zone]
		,reserved_for
		,container_type
		,stop_id
		,parent_hu_id
		,[user_id]
		,disposition
		,[weight]
		,shipment_number)
	 SELECT 
		 hum.hu_id
		,hum.[type]
		,hum.control_number
		,hum.location_id
		,hum.subtype
		,hum.[status]
		,hum.fifo_date
		,hum.wh_id
		,hum.load_position
		,hum.haz_material
		,hum.load_id
		,hum.load_seq
		,hum.ver_flag
		,hum.[zone]
		,hum.reserved_for
		,hum.container_type
		,hum.stop_id
		,hum.parent_hu_id
		,hum.[user_id]
		,hum.disposition
		,hum.[weight]
		,@shipment_number
	FROM t_hu_master hum WITH(NOLOCK)
	WHERE hum.load_id = @in_load
		AND hum.wh_id = @in_wh_id 
		AND hum.[type] = 'LO'		

	INSERT INTO t_stored_item_shipped
	(	[sequence]								
		,item_number							
		,actual_qty							
		,unavailable_qty						
		,[status]							
		,wh_id									
		,location_id							
		,fifo_date								
		,expiration_date						
		,reserved_for							
		,lot_number							
		,inspection_code						
		,[type]									
		,put_away_location						
		,stored_attribute_id					
		,hu_id									
		,shipment_number						
		,variant_code			)					
	 SELECT
		sto.[sequence]
		,sto.item_number
		,sto.actual_qty
		,sto.unavailable_qty
		,sto.[status]
		,sto.wh_id
		,sto.location_id
		,sto.fifo_date
		,sto.expiration_date
		,sto.reserved_for
		,sto.lot_number
		,sto.inspection_code
		,sto.[type]
		,sto.put_away_location
		,sto.stored_attribute_id
		,sto.hu_id
		,@shipment_number
		,sto.variant_code		
	FROM t_stored_item sto WITH(NOLOCK)
	INNER JOIN t_hu_master_shipped hum WITH(NOLOCK)
		ON sto.hu_id = hum.hu_id
		AND sto.wh_id = hum.wh_id 
	WHERE hum.load_id = @in_load
		AND hum.wh_id = @in_wh_id
		AND hum.[type] = 'LO'
	
	UPDATE t_load_master 
	SET [status] = 'SHIPPED'
		,seal_number = @in_seal
		,actual_ship_date = GETDATE()
	WHERE wh_id = @in_wh_id
		AND load_id = @in_load

	UPDATE t_pick_master 
	SET [status] = 'SHIPPED' 
	WHERE wh_id = @in_wh_id
		AND load_id = @in_load

	UPDATE t_pick_detail
	SET [status] = 'SHIPPED' 
		,shipped_quantity = picked_quantity
	WHERE wh_id = @in_wh_id
		AND load_id = @in_load

	UPDATE t_order
	SET [status] = 'S'
		,actual_ship_date = GETDATE()
	WHERE load_id = @in_load
		AND wh_id = @in_wh_id

	--STS 20170804
	--Update order to shipped if all LPNs have been
	--shipped regardless of what load they were on
	--This is primarily for transfer orders
	UPDATE o
	SET [status] = 'S'
	FROM t_order o
	INNER JOIN t_hu_master hum WITH (NOLOCK)
		ON o.order_number = hum.control_number
		AND o.wh_id = hum.wh_id
	WHERE o.[status] <> 'S'
		AND hum.load_id = @in_load
		AND hum.wh_id = @in_wh_id
		AND hum.[type] = 'LO'
		AND NOT EXISTS
					(	SELECT 1
						FROM t_hu_master hum2 WITH (NOLOCK)
						INNER JOIN t_load_master lm WITH (NOLOCK)
							ON hum2.load_id = lm.load_id
							AND hum2.wh_id = lm.wh_id
						WHERE hum2.control_number = o.order_number
							AND hum2.wh_id = o.wh_id
							AND lm.[status] <> 'SHIPPED' )

	--STS 20170804
	--Update load to shipped if all orders have been
	--shipped regardless of what load they were on
	--This is primarily for transfer orders
	UPDATE lm
	SET [status] = 'SHIPPED'
	FROM t_load_master lm
	INNER JOIN t_order o WITH (NOLOCK)
		ON lm.load_id = o.load_id
		AND lm.wh_id = o.wh_id
	INNER JOIN t_hu_master hum WITH (NOLOCK)
		ON o.order_number = hum.control_number
		AND o.wh_id = hum.wh_id
	WHERE lm.[status] <> 'SHIPPED'
		AND hum.load_id = @in_load
		AND hum.wh_id = @in_wh_id
		AND hum.[type] = 'LO'
		AND NOT EXISTS
					(	SELECT 1
						FROM t_order o2 WITH (NOLOCK)
						WHERE o2.load_id = lm.load_id
						AND o2.wh_id = lm.wh_id
						AND o2.[status] <> 'S' )

	DELETE sto
	FROM t_stored_item sto 
	INNER JOIN t_hu_master_shipped hum 
		ON sto.hu_id = hum.hu_id
		AND sto.wh_id = hum.wh_id 
	WHERE hum.load_id = @in_load
		AND hum.wh_id = @in_wh_id
		AND hum.[type] = 'LO'

	DELETE hum
	FROM t_hu_master hum 
	INNER JOIN t_hu_master_shipped hum2 
		ON hum.hu_id = hum2.hu_id
		AND hum.wh_id = hum2.wh_id 
	WHERE hum2.load_id = @in_load
		AND hum2.wh_id = @in_wh_id
		AND hum.[type] = 'LO'

	COMMIT TRAN

	--	--Create transaction record
	INSERT INTO t_tran_log_holding(
		tran_type,
		[description],
		start_tran_date,
		start_tran_time,
		end_tran_date,
		end_tran_time,
		employee_id,
		wh_id,
		load_id,
		generic_attribute_1,
		generic_attribute_2,
		sys_device,
		calling_procedure,
		shipment_id
	)
	SELECT
		'370',                 
		'Load Management Ship Confirm',		   
		GETDATE(),			   
		GETDATE(),			   
		GETDATE(),			   
		GETDATE(),			   
		ISNULL(@employee,@in_ww_username),		
		@in_wh_id,   
		@in_load  , 					   		   
		@in_trailer	,	
		LEFT (@in_seal ,500) ,	
		'HJONE',		
		OBJECT_NAME(@@PROCID),
		@shipment_number

		--BEW 20221229
		--set tote flag from temp table 
		UPDATE ord
		SET ord.tote_count_flag = od.tote_count_flag
		FROM #order_data od
		INNER JOIN t_order ord 
			ON ord.order_number = od.order_number
			AND ord.wh_id = od.wh_id 
		WHERE od.stop_rank = 1 

	--STS 20170913 - Create entry in pod queue for
	----Descartes interface
	--INSERT INTO t_pod_queue
	--(	load_id,
	--	wh_id,
	--	queue_status )
	--SELECT
	--	@in_load,
	--	@in_wh_id,
	--	0
	--BEW 20220705 - Comment out above, added below for determining to send Will Call Load to POD(Descartes) or not
			IF EXISTS 
				(
					SELECT 1
					FROM t_order o WITH (NOLOCK)
					INNER JOIN t_whse_control w WITH (NOLOCK)
						ON w.wh_id = o.wh_id
						AND w.control_type = 'WILL_CALL_POD' 
					WHERE [load_id] = @in_load
						AND (RIGHT(ISNULL(o.carrier, ''), 2) = ISNULL(c1,'WC')) --searching for carrier ending in "WC"
						AND o.wh_id = @in_wh_id 
						AND next_value = 1 --flagged as yes to send WC to POD
						AND NOT EXISTS (SELECT 1 FROM t_pod_queue q WITH (NOLOCK) --(7.0)
										WHERE @in_wh_id = q.wh_id 
											AND @in_load = q.load_id ) 
											
				) 
			INSERT INTO t_pod_queue 
				(	load_id
					,wh_id
					,queue_status
				)
			SELECT
					@in_load
					,@in_wh_id
					,0
			--else if not WC Carrier, we send to POD 
			ELSE IF EXISTS 
				(
					SELECT 1
					FROM t_order o WITH (NOLOCK)
					WHERE o.load_id = @in_load
						AND o.wh_id = @in_wh_id  
						AND (RIGHT(ISNULL(o.carrier, ''), 2) <> 'WC' OR @in_load like '%ADD%') --always insert non will call orders,. ignore ADD
						AND RIGHT(ISNULL(o.carrier, ''), 3) <> 'TRF'--(8.0) Ignore Transfer Orders
						AND NOT EXISTS (SELECT 1 FROM t_pod_queue q WITH (NOLOCK) --(7.0) 
										WHERE @in_wh_id = q.wh_id 
											AND @in_load = q.load_id ) 
				)  
			INSERT INTO t_pod_queue 
				(	load_id
					,wh_id
					,queue_status
				)
			SELECT 
					@in_load
					,@in_wh_id
					,0
				
--9.0 Begin

	INSERT INTO t_pod_shipments 
		(wh_id, customer_code, load_id, order_number, shipment_date, stop_id, uom_qty, product_type, create_date) 

		SELECT pkd.wh_id 
			,c.customer_code
			,pkd.load_id
			,pkd.order_number
			,o.earliest_ship_date 			
			,o.stop_id
			,SUM(pkd.planned_quantity / uom.conversion_factor) as uom_qty 
			,itm.product_type 
			,GETDATE() 			
		FROM t_pick_detail pkd WITH (NOLOCK)
		INNER JOIN t_item_master itm WITH (NOLOCK)
			ON pkd.wh_id = itm.wh_id 
			AND pkd.item_number = itm.item_number 
		INNER JOIN t_item_uom uom WITH (NOLOCK)
			ON pkd.wh_id = uom.wh_id
			AND pkd.item_number = uom.item_number
			AND pkd.uom = uom.uom 
		INNER JOIN t_order o WITH (NOLOCK) 
			ON pkd.wh_id = o.wh_id 
			AND pkd.order_number = o.order_number 
		INNER JOIN t_customer c WITH (NOLOCK) 
			ON o.customer_id = c.customer_id 
		WHERE pkd.load_id = @in_load
			AND pkd.wh_id = @in_wh_id  
			AND itm.product_type IN ('LILCIG', 'ECIG', 'CIG', 'CIGP', 'SNF', 'SNFP')  
			AND pkd.picked_quantity >  0 
			AND ISNULL(o.order_type, '') <> 'TRANSFER' --Exclude Transfers 
		GROUP BY pkd.wh_id, pkd.load_id, pkd.order_number, itm.product_type, o.stop_id, c.customer_code, o.earliest_ship_date
				
--(9.0) End 

	GOTO EXIT_LABEL
END TRY

BEGIN CATCH    
		SET @error_num = ERROR_NUMBER()
		SET @error_msg = CONVERT(NVARCHAR, ERROR_NUMBER()) + ' ' + ERROR_MESSAGE()
		

		IF @@TRANCOUNT > 0
			ROLLBACK TRAN
		
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
