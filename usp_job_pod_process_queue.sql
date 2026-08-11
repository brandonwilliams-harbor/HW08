USE [AAD]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[usp_job_pod_process_queue] 
	@in_debug INT = 0 

AS

BEGIN 

SET NOCOUNT ON;
/****************************************************************************************************************************************************************************************

  Object: [usp_job_pod_process_queue]
  Description: Process the point of delivery queue to generate xml for Descartes interface

ChangeLog:
 Version	Date		Intials		Repo	Notes
  -------	--------	-------		-----	-----------------------------------------------------
  1.0		20170913	STS					Created 
  2.0		20201015	NCC					Added totes_required on t_customer
  3.0		20220525	BEW-HWF				Added functionality for including Backhaul POs
  4.0		20220706	BEW-HWF	    		Comment out funcionality for excluding Will Call orders in POD interface. Now handled with WhS control SEND_WILL_POD in usp_ww_load_management_ship_confirm
  5.0		20221229	BEW-HWF				Added check for tote_count_flag and shipped_quantity to tote count calc. 
  6.0		20240102	BEW-HWF				Added logic to ignore preship_scan_gs1 loads in t_pod_queue 
  7.0		20240612	BEW-HWF				Added shipping_container to where clause of tote_expected calc. Added insert into new table t_container_shipments
  8.0		20250325    BEW-HWF     		New logic for calculating tote count from t_container_shipments instead of picking tables that are archived after 21 days. Added carrier code so we can eval WC orders for calc.
  9.0		20251110	BEW-HWF		HW04	Changed OrderedQuantity to reflecvt picked Qty instead of original order qty 
  10.0		>>>>>>>		BEW-HWF		HW08	Added tobacco count logic and tagged code. 
    --TODO: Determine where/what table to store the data, this includes inbound and outbound data. 
            --DO WE ALREADY have signature data stored somewhere? 

            
****************************************************************************************************************************************************************************************/
/********************************************************************DEV NOTE*******************************************************************************************************
This Stored Procedure differs from Prod because of RMA functionality not complete in Dev/Tst
Changes need to be added to Prod(LDC-HJDB-01) manually. 
exec usp_job_pod_process_queue 1 


***********************************************************************************************************************************************************************************/

	DECLARE
		@unique_id INT,
		@load_id NVARCHAR(30),
		@wh_id NVARCHAR(10),
		@route NVARCHAR(30),
		@order_number NVARCHAR(30),
		@hu_id NVARCHAR(22),
		@parent_hu_id NVARCHAR(22),
		@pallet_desc NVARCHAR(60),
		@hu_desc NVARCHAR(60),
		@order_xml XML,
		@pallet_xml XML,
		@unique_id_http INT,
		@pod_whse NVARCHAR(30),
		@system_name NVARCHAR(30),
		@order_uom NVARCHAR(10),
		@gln NVARCHAR(30),
		@item_number NVARCHAR(30),
		@gs1_required_flag TINYINT,
		@rma_number NVARCHAR(30),
		@sent_to_airclic TINYINT,
		@rma_xml XML,
		@reopen_xml XML,
		@po_stop INT, --BEW 20220520 
		@po_number NVARCHAR(30), --BEW 20220520 
		@po_xml	XML,
		@po_sent_to_airclic TINYINT, --BEW
		@shipment_date	DATETIME, --BEW 20220628	
		@cig_count		INT, --10.0
		@snuff_count	INT,--10.0
		@ecig_count		INT,--10.0
		@lil_cig_count	INT --10.0


	CREATE TABLE #hum_sto
	(
		hu_id					nvarchar(22),
		wh_id					nvarchar(10),
		order_number			nvarchar(30),
		load_id					NVARCHAR(60), --(7.0) 
		parent_hu_id			nvarchar(22),
		pallet_desc				nvarchar(60),
		hu_desc					nvarchar(60),
		item_number				nvarchar(30),
		item_description		nvarchar(60),
		line_number				nvarchar(30),
		quantity				int,
		cartonization_batch_id  nvarchar(60),
		class_id				nvarchar(10),
		pick_area				nvarchar(30),
		order_uom				nvarchar(10),
		gln						nvarchar(30),	
		gs1_required_flag		tinyint,
		customer_code			nvarchar(30),
		stop_id					int,
		processed				tinyint,
		totes_required			tinyint, --NCC 20201015 Add new customer field
		customer_id				int,	--NCC 20201015 Added
		tote_count_flag			TINYINT, --BEW 20221229 Start 
		ship_to_addr1			NVARCHAR(50),
		ship_to_city			NVARCHAR(30),
		ship_to_state			NVARCHAR(3),
		ship_to_zip				NVARCHAR(12), --BEW 20221229 End
		container_type			NVARCHAR(10), --(7.0)
		carrier					NVARCHAR(30) --(8.0) 

	)

	CREATE NONCLUSTERED INDEX i_hum_processed ON #hum_sto (processed)

	CREATE TABLE #customer_totes
	(
		customer_id		INT,
		customer_code	NVARCHAR(30), 
		wh_id			NVARCHAR(10),
		load_id			NVARCHAR(30),
		tote_count		INT,
		order_number NVARCHAR(30),
		ship_to_addr1	NVARCHAR(50), --(5.0) Begin
		ship_to_city	NVARCHAR(30),
		ship_to_state	NVARCHAR(3),
		ship_to_zip		NVARCHAR(12) --(5.0) End 
	)


	CREATE TABLE #rma
	(
		wh_id			nvarchar(10),
		rma_number		nvarchar(30),
		customer_code	nvarchar(30),
		stop_id			int,
		sent_to_airclic tinyint,
		processed		tinyint
	)

	CREATE TABLE #upc
	(
		wh_id		nvarchar(10),
		item_number nvarchar(30),
		upc			nvarchar(80),
		rownum		int
	)

	CREATE TABLE #gtin
	(
		wh_id		nvarchar(10),
		line_number nvarchar(10),
		upc			nvarchar(80),
		rownum		int
	)

	CREATE TABLE #po 
	(
		wh_id			NVARCHAR(10),
		po_number		NVARCHAR(30),
		vendor_code		NVARCHAR(30),
		stop_id			INT, --Default value to 0
		route_id		NVARCHAR(60), 
		line_number		NVARCHAR(20),
		item_number		NVARCHAR(60),
		sent_to_airclic TINYINT, 
		processed		TINYINT   
	) 

BEGIN TRY
	
	SELECT @system_name = c1
	FROM t_control WITH (NOLOCK)
	WHERE control_type = 'POD_SYSTEM_NAME'

	IF @@ROWCOUNT = 0
	BEGIN
		INSERT INTO t_control
		(	control_type,
			description,
			allow_edit,
			c1 )
		SELECT
			'POD_SYSTEM_NAME',
			'System name for POD',
			'Y',
			'legacySystem'

		SET @system_name = 'legacySystem'
	END

	WHILE EXISTS
	(	SELECT 1
		FROM t_pod_queue WITH (NOLOCK)
		WHERE queue_status = 0
			AND ISNULL(preship_scan_gs1, 0) = 0  ) --(6.0) 
	BEGIN
		UPDATE TOP (1) q
		SET q.queue_status = 1,
			@unique_id = q.unique_id,
			@load_id = q.load_id,
			@wh_id = q.wh_id
		FROM t_pod_queue q
		WHERE q.queue_status = 0
			AND ISNULL(q.preship_scan_gs1, 0) = 0 --(6.0) 

		SELECT @route = route_id,
				@shipment_date = earliest_ship_date 
			FROM t_load_master WITH (NOLOCK)
			WHERE load_id = @load_id
			AND wh_id = @wh_id


		--BEW PO's show as last stop for driver to service 
		SELECT @po_stop = ISNULL(MAX(stop_id),1) +1 
			FROM t_load_master lom WITH (NOLOCK)
			INNER JOIN t_order ord WITH (NOLOCK)
				ON ord.wh_id = lom.wh_id
				AND ord.load_id = lom.load_id 
			WHERE lom.load_id = @load_id
			AND lom.wh_id = @wh_id

			INSERT INTO #hum_sto
			SELECT
				hum.hu_id,
				hum.wh_id,
				pkd.order_number,
				hum.load_id, --(7.0) 
				hum.parent_hu_id,
				CONCAT(pkd.truck_builder_pallet_id,'-',pkd.truck_builder_pallet_number),
				CASE WHEN pkd.cartonization_batch_id IS NULL THEN itm.[description] ELSE CONCAT(pkd.pick_area,'-',pkd.cartonization_batch_id) END,
				sto.item_number,
				itm.[description],
				pkd.line_number,
				SUM(sto.actual_qty) / iu.conversion_factor,
				pkd.cartonization_batch_id,
				itm.class_id,
				pkd.pick_area,
				pkd.order_uom,
				c.gln,
				CASE WHEN ISNULL(itm.gs1_required_flag, 0) = 1 AND ISNULL(c.gs1_required_flag, 0) = 1 THEN 1 ELSE 0 END,
				c.customer_code,
				o.stop_id,
				0,
				c.totes_required,	--NCC 20201015 Add new customer table
				c.customer_id,		--NCC 20201015 Add customer id
				ISNULL(o.tote_count_flag, 0), --BEW 20221229 Start
				o.ship_to_addr1,
				o.ship_to_city, 
				o.ship_to_state,
				o.ship_to_zip,	--BEW 20221229 End 
				pkd.container_type, --(7.0)
				o.carrier --(8.0) 
			FROM t_hu_master_shipped hum WITH (NOLOCK)
			INNER JOIN t_stored_item_shipped sto WITH (NOLOCK)
				ON hum.hu_id = sto.hu_id
				AND hum.wh_id = sto.wh_id
			INNER JOIN t_pick_detail pkd WITH (NOLOCK)
				ON sto.[type] = pkd.pick_id
			INNER JOIN t_item_master itm WITH (NOLOCK)
				ON sto.item_number = itm.item_number
				AND sto.wh_id = itm.wh_id
			INNER JOIN t_item_uom iu WITH (NOLOCK)
				ON pkd.item_number = iu.item_number
				AND pkd.order_uom = iu.uom --STS 20220218 - Changed from pkd.uom to pkd.order_uom
				AND pkd.wh_id = iu.wh_id
			INNER JOIN t_order o WITH (NOLOCK)
				ON pkd.order_number = o.order_number
				AND pkd.wh_id = o.wh_id
			INNER JOIN t_customer c WITH (NOLOCK)
				ON o.customer_id = c.customer_id
			WHERE hum.load_id = @load_id
				AND hum.wh_id = @wh_id
				--STS 20180118 - Don't send willcall routes to descartes, unless they are addon route
				--AND (RIGHT(ISNULL(o.carrier, ''), 2) <> 'WC' OR @route like '%ADD%')  
				--BEW 20220705 comment out above, WC insert handled in usp_ww_load_management_ship_confirm
			GROUP BY
				hum.hu_id,
				hum.wh_id,
				pkd.order_number,
				hum.load_id, --(7.0) 
				hum.parent_hu_id,
				sto.item_number,
				itm.[description],
				pkd.line_number,
				pkd.truck_builder_pallet_id,
				pkd.truck_builder_pallet_number,
				pkd.cartonization_batch_id,
				pkd.pick_area,
				pkd.order_uom,
				iu.conversion_factor,
				itm.class_id,
				c.gln,
				itm.gs1_required_flag,
				c.gs1_required_flag,
				c.customer_code,
				c.customer_id,	--NCC 20201015 Added
				o.stop_id,
				c.totes_required,	--NCC 20201015 Added
				o.tote_count_flag, --BEW 20221229 Start
				o.ship_to_addr1,
				o.ship_to_city, 
				o.ship_to_state,
				o.ship_to_zip,	--BEW 20221229 End 
				pkd.container_type, --(7.0)
				o.carrier --(8.0) 
			
			--BEW 20221229 Added Debug
			IF ISNULL(@in_debug, 0) > 0
			BEGIN
				SELECT * FROM #hum_sto 
			END


		--NCC 20201015 Delete customer
		DELETE #customer_totes	
	
		--NCC 2021015 insert customers that have tote_required
		INSERT INTO #customer_totes
		SELECT DISTINCT
			customer_id,
			customer_code, --(8.0) 
			wh_id,
			'',
			0,
			order_number, --BEW 20221229 Start 
			ship_to_addr1, 
			ship_to_city,
			ship_to_state, 
			ship_to_zip  --BEW 20221229 End
		FROM #hum_sto
		WHERE ISNULL(totes_required, 0) = 1
			AND processed = 0 --STS 20220214
			AND ISNULL(tote_count_flag, 0) = 1 --BEW 20221229

		--BEW 20221229 Added Debug
		IF ISNULL(@in_debug, 0) > 0
		BEGIN
			SELECT * FROM #customer_totes  
		END

--(8.0) Begin Comment Out 
--Comment out section 21 days from 3/25/25 	
		--NCC 20201015 Get most recent load id for each customer
		UPDATE ct
		SET load_id = o.load_id
		FROM #customer_totes ct
		CROSS APPLY (
			SELECT TOP 1 o.load_id
			FROM t_order o WITH(NOLOCK)
			INNER JOIN t_load_master l WITH(NOLOCK)
				ON l.wh_id = o.wh_id
				AND l.load_id = o.load_id
			WHERE o.wh_id = ct.wh_id
				--AND o.customer_id = ct.customer_id --Not dependent on customer, if address matches then same customer 
				AND o.ship_to_addr1	= ct.ship_to_addr1 --BEW 20221229 Start 		
				AND o.ship_to_city 	= ct.ship_to_city 
				AND o.ship_to_state	= ct.ship_to_state
				AND o.ship_to_zip   = ct.ship_to_zip --BEW 20221229 End  
				AND o.load_id <> @load_id
				AND ISNULL(o.order_type, '') <> 'TRANSFER'
				AND RIGHT(ISNULL(o.carrier, ''), 2) <> 'WC'
			ORDER by created_date DESC
		) o
--(8.0) End  Comment Out 
		--NCC 20201015 Get count of totes from previous load found
		UPDATE ct
		SET tote_count = s.tote_count
		FROM #customer_totes ct
		CROSS APPLY (
			SELECT COUNT(DISTINCT hu_id) AS tote_count
			FROM t_pick_master pkm WITH(NOLOCK)
			INNER JOIN t_pick_detail pkd WITH(NOLOCK)
				ON pkm.pick_master_id = pkd.pick_master_id
			INNER JOIN t_order o WITH(NOLOCK)
				ON pkd.order_number = o.order_number
				AND pkd.wh_id = o.wh_id
			INNER JOIN t_container con WITH (NOLOCK) --(7.0) 
				ON pkm.wh_id = con.wh_id 
				AND pkm.container_type = con.container_type
			WHERE o.wh_id = ct.wh_id
				AND o.load_id = ct.load_id
				AND ISNULL(o.order_type, '') <> 'TRANSFER'
				AND RIGHT(ISNULL(o.carrier, ''), 2) <> 'WC'
				--AND pkm.container_type IN ('TOTE', 'OTP Tote', 'OTP')
				AND ISNULL(con.shipping_container, 0) = 1 --(7.0) 
				--BEW 20221229 Start 
				AND pkd.shipped_quantity > 0 
				--AND o.customer_id = ct.customer_id --Not dependent on customer, if address matches then same customer
				AND ( --AND/OR if customer changes address. 
					o.customer_id = ct.customer_id 
						OR 
						(	o.ship_to_addr1	= ct.ship_to_addr1 		
							AND o.ship_to_city 	= ct.ship_to_city 
							AND o.ship_to_state	= ct.ship_to_state
							AND o.ship_to_zip   = ct.ship_to_zip 
						) 
				  )
				--BEW 20221229 End  
			--GROUP BY o.customer_id
		) s	
--(8.0) Begin new tote calc. 
		--using rowcount for now because t_container_shipments previously did not insert all records if customer had multiple accounts/stops on route. 
		--was only inserting the last order/stop combo. I will remove the above calculation in 21 days from 3/25/25	
		IF EXISTS (SELECT 1 FROM #customer_totes WHERE tote_count = 0 )
		BEGIN 
			IF @in_debug = 1
			BEGIN 
				SELECT 'Using New Tote Count Calculation'
			END 


			UPDATE ct
			SET tote_count = s.tote_count
			FROM #customer_totes ct
			CROSS APPLY (
				SELECT TOP 1 ISNULL(SUM(cs.shipped_qty), 0)  AS tote_count
						,CAST(cs.shipment_date AS date) AS ship_date 
					-- ,cs.customer_code 
					,cs.ship_to_addr1
					,cs.ship_to_city
					,cs.ship_to_state
					,cs.ship_to_zip 
				FROM t_container_shipments cs WITH (NOLOCK)
				INNER JOIN t_customer c WITH (NOLOCK)
					ON cs.customer_code = c.customer_code 
				WHERE (cs.load_id NOT LIKE '%WC%' 
							OR cs.load_id NOT LIKE '%CC%' 
							OR cs.load_id NOT LIKE '%UP%' 
						) 
					AND RIGHT(ISNULL(cs.carrier, ''), 2) <> 'WC'
					AND CAST(cs.shipment_date AS DATE) < CAST(GETDATE() AS DATE) 
					AND ( --AND/OR if customer changes address. 
						c.customer_code = ct.customer_code
							OR 
							(	c.customer_addr1 = ct.ship_to_addr1 		
								AND c.customer_city = ct.ship_to_city 
								AND c.customer_state = ct.ship_to_state
								AND c.customer_zip = ct.ship_to_zip 
							) 
					)
				GROUP BY CAST(cs.shipment_date AS date) --,cs.customer_code, 
						,cs.ship_to_addr1
					,cs.ship_to_city
					,cs.ship_to_state
					,cs.ship_to_zip 
				ORDER BY CAST(cs.shipment_date AS date) DESC 
					--BEW 20221229 End  
			) s	
			WHERE ct.tote_count = 0 --Remove in 21 days 
		END 
--(8.0) End  new tote calc. 

		--BEW 20221229 Added Debug
		IF ISNULL(@in_debug, 0) > 0
		BEGIN
			SELECT * FROM #customer_totes  
		END

		--STS 2021119 - Track tote counts sent to Descartes
		INSERT INTO t_customer_totes (wh_id, customer_code, customer_name, load_id, tote_expected, create_date)
		SELECT
			ct.wh_id,
			c.customer_code,
			c.customer_name,
			ct.load_id,
			ct.tote_count,
			GETDATE()
		FROM #customer_totes ct
		INNER JOIN t_customer c WITH (NOLOCK)
			ON ct.customer_id = c.customer_id
--(7.0) Begin 		
		--Insert tote counts for current shipment 
		INSERT INTO t_container_shipments 
			(wh_id, customer_code, load_id, order_number, container_type, shipped_qty, shipment_date, ship_to_addr1, ship_to_city, ship_to_state, ship_to_zip, stop_id, carrier)
		SELECT 	hs.wh_id
				,hs.customer_code
				,hs.load_id
				,hs.order_number
				,hs.container_type
				,COUNT(DISTINCT hs.hu_id) AS shipped_qty 
				,GETDATE() AS shipment_date
				,hs.ship_to_addr1
				,hs.ship_to_city
				,hs.ship_to_state
				,hs.ship_to_zip
				,hs.stop_id
				,hs.carrier --(8.0)
		FROM #hum_sto hs 
		INNER JOIN t_container con WITH (NOLOCK)
			ON hs.wh_id = con.wh_id
			AND hs.container_type = con.container_type 
		WHERE ISNULL(hs.totes_required, 0) = 1
			--AND ISNULL(hs.tote_count_flag, 0) = 1 --(8.0) Removed. Was excluding first orders if customer had multple stops or orders on route 
			AND hs.processed = 0 
			AND ISNULL(con.shipping_container, 0) = 1 
			AND hs.quantity > 0 
		GROUP BY hs.wh_id
				,hs.customer_code
				,hs.load_id
				,hs.order_number
				,hs.container_type
				,hs.ship_to_addr1
				,hs.ship_to_city
				,hs.ship_to_state
				,hs.ship_to_zip	
				,hs.stop_id
				,hs.carrier --(8.0) 
--(7.0) End 
	
		--BEW 20221229 Added Debug
		IF ISNULL(@in_debug, 0) > 0
		BEGIN
			SELECT 'totes', * FROM #customer_totes  
		END
			
		--BEW 20220524 new backhaul PO addition 
		INSERT INTO #po	
			SELECT 
				pom.carrier_scac as wh_id,
				pom.po_number,
				pom.vendor_code,
				@po_stop, --stop_id set earlier
				route_id,
				pod.line_number,
				pod.item_number, 
				pom.sent_to_airclic, 
				0 --processed
			FROM t_po_master pom WITH (NOLOCK)
			INNER JOIN t_po_detail pod WITH (NOLOCK)
				ON pod.po_number = pom.po_number
				AND pod.wh_id = pom.wh_id 
			LEFT JOIN t_po_backhaul_airclic pba WITH (NOLOCK)
				ON pba.po_number = pom.po_number
				AND pba.wh_id = pom.wh_id 
			WHERE --pom.wh_id = @wh_id
				 pom.[status] = 'O'
				--AND ISNULL(pom.received_by_airclic, 0) = 0 --comment out, we can receive from airclic but not be picked up by driver
				AND ISNULL(pba.[status],'') <> 'COMPLETE' --indicates driver picked up po 
				AND pom.route_id = @route 
				AND pom.carrier_scac = @wh_id
				AND pom.shipment_date = @shipment_date --BEW 20220628 
				AND NOT EXISTS ( SELECT 1 --must not have receipts 
									FROM t_receipt rec WITH (NOLOCK)
									INNER JOIN t_po_master pom WITH (NOLOCK)
										ON pom.po_number = rec.po_number
										AND pom.carrier_scac = rec.wh_id 
									WHERE pom.route_id = @route
										AND pom.carrier_scac = @wh_id
										AND pom.shipment_date = @shipment_date) --BEW 20220810, missing where to exclude rececipts for other pos that were on same route i		
				AND EXISTS ( SELECT 1 --PO pickup date must equal route ship date 
							FROM t_load_master lom WITH (NOLOCK)
							INNER JOIN t_po_master pom WITH (NOLOCK)
								ON pom.route_id = lom.route_id
								AND pom.carrier_scac = lom.wh_id 
							WHERE pom.route_id = @route 
								AND pom.carrier_scac = @wh_id
								AND pom.shipment_date = lom.earliest_ship_date
								AND lom.load_id = @load_id) --BEW 20220628
			IF ISNULL(@in_debug, 0) > 0
			BEGIN
				SELECT * FROM #po 
			END
		DELETE #rma
		--BEW 20211206 commented out, moving tote tracking to prod
		-- customer returns not ready for prod
		--INSERT INTO #rma
		--SELECT
		--	rma.wh_id,
		--	rma.rma_number,
		--	rma.customer_code,
		--	NULL, --stop_id, update later
		--	ISNULL(rma.sent_to_airclic, 0),
		--	0
		--FROM t_rma_master rma WITH (NOLOCK)
		--INNER JOIN t_rma_detail rmad WITH (NOLOCK)
		--	ON rma.rma_number = rmad.rma_number
		--	AND rma.wh_id = rmad.wh_id
		--WHERE rma.wh_id = @wh_id
		--AND rma.status = 'OPEN'
		--AND rma.customer_code IN (SELECT DISTINCT customer_code FROM #hum_sto WHERE processed = 0)
		--AND ISNULL(rmad.qty_receivied, 0) < qty
		--AND ISNULL(rmad.rcvd_by_airclic, 0) = 0
		----Route must exist in the table or all route mode must be enabled for rma to be sent
		--AND (SELECT TOP 1
		--		[route]
		--	FROM t_rma_pod_routes WITH (NOLOCK)
		--	WHERE wh_id = @wh_id
		--	ORDER BY
		--		CASE WHEN [route] = @route THEN 0
		--			WHEN [route] = 'ALL' THEN 1
		--			ELSE 2 END ) IN (@route, 'ALL')
		--GROUP BY
		--	rma.wh_id,
		--	rma.rma_number,
		--	rma.customer_code,
		--	rma.sent_to_airclic

		--UPDATE #rma
		--SET stop_id =
		--(	SELECT TOP 1 stop_id
		--	FROM #hum_sto hs
		--	WHERE hs.customer_code = #rma.customer_code)	

		SELECT @pod_whse = pod_whse
		FROM t_whse WITH (NOLOCK)
		WHERE wh_id = @wh_id

		IF @in_debug = 1
		BEGIN
			SELECT @load_id as load_id,* FROM #hum_sto WHERE processed = 0
			SELECT * FROM #customer_totes ct
		outer apply  (
			SELECT TOP 1 o.load_id
			FROM t_order o WITH(NOLOCK)
			INNER JOIN t_load_master l WITH(NOLOCK)
				ON l.wh_id = o.wh_id
				AND l.load_id = o.load_id
			WHERE o.wh_id = ct.wh_id
				AND o.customer_id = ct.customer_id
				AND o.load_id <> @load_id
				AND ISNULL(o.order_type, '') <> 'TRANSFER'
				AND RIGHT(ISNULL(o.carrier, ''), 2) <> 'WC'
			ORDER by created_date
		) o
			--SELECT '#rma', * FROM #rma --BEW RMA logic commented out
		END

		WHILE EXISTS (SELECT 1 FROM #hum_sto WHERE processed = 0)
		BEGIN
			SELECT TOP 1
				@order_number = order_number
			FROM #hum_sto
			WHERE processed = 0

			--Create a record in the http queue table
			INSERT INTO t_pod_queue_http
					(	load_id,
						order_number,
						wh_id,
						message_type )
					SELECT
						@load_id,
						@order_number,
						@wh_id,
						'addOrderAndCustomerRequest'

			SET @unique_id_http = SCOPE_IDENTITY()	

			DELETE #gtin
			--GS1 data 
			INSERT INTO #gtin
			SELECT
				ord.wh_id,
				ord.line_number,
				upc.upc,
				ROW_NUMBER() OVER (PARTITION BY ord.wh_id, ord.line_number ORDER BY upc.upc DESC)
			FROM t_order o WITH (NOLOCK)
			INNER JOIN t_customer c WITH (NOLOCK)
				ON o.customer_id = c.customer_id
			INNER JOIN t_order_detail ord WITH (NOLOCK) 
				ON o.order_number = ord.order_number
				AND o.wh_id = ord.wh_id
			INNER JOIN t_item_upc upc WITH (NOLOCK)
				ON upc.item_number = ord.item_number
				AND upc.wh_id = ord.wh_id
			INNER JOIN t_item_master itm WITH (NOLOCK) --BEW 20210419
				ON itm.item_number = ord.item_number
				AND itm.wh_id = ord.wh_id 
			WHERE o.order_number = @order_number
			AND o.wh_id = @wh_id
			AND ord.order_uom = 'CS'
			AND LEN(upc.upc) BETWEEN 12 and 14 --BEW 20210419
			AND ISNULL(c.gln, '') <> ''
			AND itm.gs1_required_flag = 1 --BEW 20210419
			AND  ISNULL(c.gs1_required_flag, '') <> '' --BEW 20220223  for customers that have GLN but are not gs1 required
			ORDER BY
				CASE upc.uom WHEN 'CS' THEN 0 ELSE 1 END, --Prefer case first
				upc.modified_datetime DESC	

--10.0 Begin 
		--Set tobacco counts here, rest values to 0 at end 

		SELECT @cig_count = ISNULL(SUM(uom_qty), 0) 
		FROM t_pod_shipments WITH (NOLOCK)
		WHERE load_id = @load_id 
			AND wh_id = @wh_id 
			AND order_number = @order_number 
			AND product_type IN ('CIG', 'CIGP')

		SELECT @lil_cig_count = ISNULL(SUM(uom_qty), 0) 
		FROM t_pod_shipments WITH (NOLOCK)
		WHERE load_id = @load_id 
			AND wh_id = @wh_id 
			AND order_number = @order_number 
			AND product_type = 'LILCIG'
		
		SELECT @snuff_count = ISNULL(SUM(uom_qty), 0) 
		FROM t_pod_shipments WITH (NOLOCK)
		WHERE load_id = @load_id 
			AND wh_id = @wh_id 
			AND order_number = @order_number 
			AND product_type IN ('SNF', 'SNFP')

		SELECT @ecig_count = ISNULL(SUM(uom_qty), 0) 
		FROM t_pod_shipments WITH (NOLOCK)
		WHERE load_id = @load_id 
			AND wh_id = @wh_id 
			AND order_number = @order_number 
			AND product_type = 'ECIG' 

		IF @in_debug =1 
		BEGIN 
			SELECT @cig_count as cig_count
					,@lil_cig_count as lil_cig_count
					,@snuff_count as snuff_count
					,@ecig_count as ecig_count 
		END 
		
--10.0 End 

			SELECT @order_xml = 
			(	SELECT
					@unique_id_http as "@transactionId",
					FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
					@system_name as systemName,
					@pod_whse as centerNumber,
					@route as routeNumber,
					(	SELECT
							'false' as "@mailConfirmationRequired",
							c.customer_code as customerNumber,
							c.customer_name as customerName,
						--	0 as backhaulOrder, --BEW 20220601
							--c.chain_name as chainName, --BEW 20210331 
							'true' as printReceipt
						FOR XML PATH('customer'), TYPE
					),
					(	SELECT
							o.ship_to_addr1 as addressLine1,
							o.ship_to_addr2 as addressLine2,
							o.ship_to_city as city,
							o.ship_to_state as state,
							o.ship_to_zip as zipCode,
							'USA' as country
						FOR XML PATH('customerAddress'), TYPE
					),
					(	SELECT
							o.ship_to_name as firstName,
							o.ship_to_name as lastName,
							LEFT(o.ship_to_addr1, 30) as location,
							'true' as active
						FOR XML PATH('contact'), TYPE
					),
					(	SELECT
							CONCAT(o.stop_id, @route) as groupNumber,	
						(	
							SELECT
								'goods' as "@typeName",
								'an order that consists of goods' as "@typeDescription",
								'false' as "@canceled",
								o.order_number as orderNumber,
								o.order_date as orderDate,
								CASE WHEN ISNULL(o.cust_po_number, '') <> '' THEN o.cust_po_number END as poNumber,
								FORMAT(o.earliest_ship_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
								FORMAT(o.actual_ship_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
								o.stop_id as expectedServiceSequence,
								'0' as expectedPayment,
								'false' as backOrder,
								(SELECT TOP 1 'You have a planned return on this stop. Printer Needed.' FROM #rma r WHERE r.customer_code = c.customer_code) as alert,
								'false' as acceptAll,
								'Highjump WMS POD Interface' as serviceInstructions,
								'false' as sendWireless,
								'false' as scheduledEmpty,
								0 as expectedItemQuantity,
								'true' as authorizedSignerRequired,
								--BEW 20220223 and ISNULL(c.gs1_required_flag, '') <> '' for customers that have GLN but are not gs1 required 
								CASE WHEN ISNULL(c.gln, '') <> '' and ISNULL(c.gs1_required_flag, 0) <> 0 THEN 'destGLN' END as "property/@name",
								CASE WHEN ISNULL(c.gln, '') <> '' and ISNULL(c.gs1_required_flag, 0) <> 0 THEN 'Customer Destination GLN' END as "property/@description",
								CASE WHEN ISNULL(c.gln, '') <> '' and ISNULL(c.gs1_required_flag, 0) <> 0 THEN 'string' END as "property/@dataType",
								CASE WHEN ISNULL(c.gln, '') <> '' and ISNULL(c.gs1_required_flag, 0) <> 0 THEN c.gln END as property,
								NULL,
								CASE WHEN ISNULL(ct.tote_count, 0) <> 0 THEN 'ExpectedPickups' END as "property/@name",
								CASE WHEN ISNULL(ct.tote_count, 0) <> 0 THEN 'Expected Pickups' END as "property/@description",
								CASE WHEN ISNULL(ct.tote_count, 0) <> 0 THEN 'string' END as "property/@dataType",
								CASE WHEN ISNULL(ct.tote_count, 0) <> 0 THEN ct.tote_count END as property,
								--chain name 20210331 BEW. Descartes uses to determine where to send GS1 files. 
								NULL,
								CASE WHEN ISNULL(c.chain_name, '') <> '' and ISNULL(c.gs1_required_flag, 0) <> 0 THEN 'chainName' END as "property/@name",
								CASE WHEN ISNULL(c.chain_name, '') <> '' and ISNULL(c.gs1_required_flag, 0) <> 0 THEN 'GS1 Chain Name' END as "property/@description",
								CASE WHEN ISNULL(c.chain_name, '') <> ''  and ISNULL(c.gs1_required_flag, 0) <> 0 THEN 'string' END as "property/@dataType",
								CASE WHEN ISNULL(c.chain_name, '') <> '' and ISNULL(c.gs1_required_flag, 0) <> 0 THEN c.chain_name END as property,
								--10.0 Begin 
								--Add tobacco logic here 
								NULL, 
								CASE WHEN ISNULL(@cig_count, 0) <> 0 THEN 'ExpectedCigCount' END as "property/@name", 
								CASE WHEN ISNULL(@cig_count, 0) <> 0 THEN 'Expected Cig Count' END AS "property/@description",
								CASE WHEN ISNULL(@cig_count, 0) <> 0 THEN 'string' END as "property/@dataType",
								CASE WHEN ISNULL(@cig_count, 0) <> 0 THEN @cig_count END as property,
								NULL, 
								CASE WHEN ISNULL(@lil_cig_count, 0) <> 0 THEN 'ExpectedLilCigCount' END as "property/@name", 
								CASE WHEN ISNULL(@lil_cig_count, 0) <> 0 THEN 'Expected Lil Cig Count' END AS "property/@description",
								CASE WHEN ISNULL(@lil_cig_count, 0) <> 0 THEN 'string' END as "property/@dataType",
								CASE WHEN ISNULL(@lil_cig_count, 0) <> 0 THEN @lil_cig_count END as property,	
								NULL, 
								CASE WHEN ISNULL(@ecig_count, 0) <> 0 THEN 'ExpectedECigCount' END as "property/@name", 
								CASE WHEN ISNULL(@ecig_count, 0) <> 0 THEN 'Expected E-Cig Count' END AS "property/@description",
								CASE WHEN ISNULL(@ecig_count, 0) <> 0 THEN 'string' END as "property/@dataType",
								CASE WHEN ISNULL(@ecig_count, 0) <> 0 THEN @ecig_count END as property,
								NULL, 
								CASE WHEN ISNULL(@snuff_count, 0) <> 0 THEN 'ExpectedSnuffCount' END as "property/@name", 
								CASE WHEN ISNULL(@snuff_count, 0) <> 0 THEN 'Expected Snuff Count' END AS "property/@description",
								CASE WHEN ISNULL(@snuff_count, 0) <> 0 THEN 'string' END as "property/@dataType",
								CASE WHEN ISNULL(@snuff_count, 0) <> 0 THEN @snuff_count END as property,		
								--10.0 End 
								(	
									SELECT 
										[@typeName],
										[@typeDescription],
										[@purposeNumber],
										lineNumber,
										[description],
										orderedQuantity,
										fulfilledQuantity,
										serviceQuantity,
										[gs1Number/@type],
										gs1Number,
										[property/@name],
										[property/@description],
										[property/@dataType],
										property, --BEW 20211206								
										identification
									FROM
									(
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											CASE im.class_id 
												WHEN 'CIG' THEN '20'
												WHEN 'CLR' THEN '3'
												WHEN 'DRY' THEN '4'
												WHEN 'FRZ' THEN '6'
												WHEN 'PRO' THEN '7'
												ELSE '13' --Misc
											END as "@purposeNumber",
											hs.hu_id + CASE WHEN hs.gs1_required_flag = 1 THEN '-GS1' ELSE '' END as lineNumber,
											im.[description] as [description],
											SUM(hs.quantity) as orderedQuantity,
											0 as fulfilledQuantity,
											SUM(hs.quantity) as serviceQuantity,
											CASE WHEN hs.gs1_required_flag = 1 THEN 'GTIN' END as "gs1Number/@type", --STS 20220223 - Only send GTIN if GS1 required
											CASE WHEN hs.gs1_required_flag = 1 THEN (SELECT TOP 1 RIGHT('000' + upc, 14) FROM t_item_upc u WITH (NOLOCK) WHERE u.item_number = od.item_number AND u.wh_id = od.wh_id AND u.uom = 'CS' AND LEN(upc) BETWEEN 12 and 14  ORDER BY modified_datetime DESC) END as gs1Number,
											CASE WHEN ISNULL(im.net_weight_barcode, 0) <> 0 THEN 'netWeightBarcode' END as "property/@name",
											CASE WHEN ISNULL(im.net_weight_barcode, 0) <> 0 THEN 'GS1NetWeightFlag' END as "property/@description",
											CASE WHEN ISNULL(im.net_weight_barcode, 0) <> 0 THEN 'string' END as "property/@dataType",
											CASE WHEN ISNULL(im.net_weight_barcode, 0) <> 0 THEN im.net_weight_barcode END as property,
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													od.item_number as identificationNumber,
													im.[description] as [name],
													im.[description] as [description],
													(	SELECT
															od.order_uom as 'abbreviation',
															od.order_uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_order_detail od WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON od.item_number = im.item_number
											AND od.wh_id = im.wh_id			
										INNER JOIN #hum_sto hs
											ON od.line_number = hs.line_number
											AND od.order_number = hs.order_number
											AND od.wh_id = hs.wh_id						
										WHERE o.order_number = od.order_number
										AND o.wh_id = od.wh_id
										AND
										(	od.order_uom = 'CS'
											AND ISNULL(c.gln, '') <> ''
											AND EXISTS (SELECT 1 FROM t_item_upc u WITH (NOLOCK) WHERE u.item_number = od.item_number AND u.wh_id = od.wh_id AND u.uom = 'CS' AND LEN(upc) BETWEEN 12 and 14) 
											--AND LEN(upc) BETWEEN 12 and 14
											--) --BEW 20210419
											
										)
										GROUP BY
											od.wh_id,
											im.class_id,
											od.item_number,
											od.line_number,
											im.[description],
											od.qty,
											od.order_uom,
											hs.hu_id,
											hs.gs1_required_flag,
											im.net_weight_barcode --BEW 20211206
										UNION ALL
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											CASE im.class_id 
												WHEN 'CIG' THEN '20'
												WHEN 'CLR' THEN '3'
												WHEN 'DRY' THEN '4'
												WHEN 'FRZ' THEN '6'
												WHEN 'PRO' THEN '7'
												ELSE '13' --Misc
											END as "@purposeNumber",
											od.line_number as lineNumber,
											im.[description] as [description],
											SUM(hs.quantity) as orderedQuantity, --(9.0)
											--CAST(od.qty AS INT) as orderedQuantity,
											0 as fulfilledQuantity,
											SUM(hs.quantity) as serviceQuantity,
											NULL as "gs1Number/@type",
											NULL as gs1Number,
											CASE WHEN ISNULL(im.net_weight_barcode, 0) <> 0 THEN 'netWeightBarcode' END as "property/@name",
											CASE WHEN ISNULL(im.net_weight_barcode, 0) <> 0 THEN 'GS1NetWeightFlag' END as "property/@description",
											CASE WHEN ISNULL(im.net_weight_barcode, 0) <> 0 THEN 'string' END as "property/@dataType",
											CASE WHEN ISNULL(im.net_weight_barcode, 0) <> 0 THEN im.net_weight_barcode END as property,
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													od.item_number as identificationNumber,
													im.[description] as [name],
													im.[description] as [description],
													(	SELECT
															od.order_uom as 'abbreviation',
															od.order_uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_order_detail od WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON od.item_number = im.item_number
											AND od.wh_id = im.wh_id			
										INNER JOIN #hum_sto hs
											ON od.line_number = hs.line_number
											AND od.order_number = hs.order_number
											AND od.wh_id = hs.wh_id						
										WHERE o.order_number = od.order_number
										AND o.wh_id = od.wh_id
										AND NOT
										(	od.order_uom = 'CS'
											AND ISNULL(c.gln, '') <> ''
											AND EXISTS (SELECT 1 FROM t_item_upc u WITH (NOLOCK) WHERE u.item_number = od.item_number AND u.wh_id = od.wh_id AND u.uom = 'CS' AND LEN(upc) BETWEEN 12 and 14)
										)
										GROUP BY
											od.wh_id,
											im.class_id,
											od.item_number,
											od.line_number,
											im.[description],
											od.qty,
											od.order_uom, 
											im.net_weight_barcode --BEW 20211206 
									) as t
									FOR XML PATH('orderItem'), TYPE
								)
							FOR XML PATH('order'), TYPE
						)
					FOR XML PATH('orders'), TYPE
				)
				FROM t_order o WITH (NOLOCK)
				INNER JOIN t_customer c WITH (NOLOCK)
					ON o.customer_id = c.customer_id
				LEFT OUTER JOIN #customer_totes ct 		--NCC 20201016 Added to get customer totes
					ON ct.wh_id = c.wh_id
					AND ct.customer_id = o.customer_id
					AND ct.order_number = o.order_number --BEW 20221229
				WHERE o.order_number = @order_number
				AND o.wh_id = @wh_id
				FOR XML PATH('addOrderAndCustomerRequest'), TYPE
			)

			IF ISNULL(@in_debug, 0) > 0
			BEGIN
				SELECT @order_xml order_xml
			END

			UPDATE t_pod_queue_http
			SET message_xml = @order_xml,
				queue_status = 0
			WHERE unique_id = @unique_id_http

			UPDATE #hum_sto
			SET processed = 1
			WHERE order_number = @order_number
		END
			
		--WHILE EXISTS (SELECT 1 FROM #hum_sto WHERE processed = 1)
		--BEGIN
		--	SELECT TOP 1
		--		@parent_hu_id = parent_hu_id,
		--		@pallet_desc = pallet_desc,
		--		@hu_id = hu_id,
		--		@hu_desc = hu_desc,
		--		@order_number = order_number,
		--		@order_uom = order_uom,
		--		@gln = gln,
		--		@item_number = item_number,
		--		@wh_id = wh_id,
		--		@gs1_required_flag = gs1_required_flag
		--	FROM #hum_sto
		--	WHERE processed = 1

		----If this is a GS1 coded case pick, do not send as an add pallet request
		--	IF @order_uom = 'CS' AND ISNULL(@gln, '') <> '' --AND ISNULL(@gs1_required_flag, 0) = 1-- (should be able to still send cases with GTIN as just cases)
		--	BEGIN
		--		IF EXISTS
		--		(	SELECT 1 FROM t_item_upc u WITH (NOLOCK)
		--			WHERE u.item_number = @item_number
		--			AND u.wh_id = @wh_id
		--			AND u.uom = 'CS'
		--			AND LEN(upc) BETWEEN 12 and 14 )
		--		BEGIN
		--			UPDATE #hum_sto
		--			SET processed = 2
		--			WHERE hu_id = @hu_id 

		--			CONTINUE
		--		END
		--	END
		--BEW ADD PO xml here 
		WHILE EXISTS (SELECT 1 FROM #po WHERE processed = 0 ) 
		BEGIN 
			SELECT TOP 1 
				@po_number = po_number,
				@po_sent_to_airclic = sent_to_airclic 
				FROM #po 
				WHERE processed = 0 

			IF @po_sent_to_airclic = 1 
			BEGIN 
			--create reopen record in the http queue table 
			--BEW 202220524
			INSERT INTO t_pod_queue_http 
			(
				load_id,
				order_number,
				wh_id,
				message_type 
			) 
			SELECT 
				@load_id,
				@po_number, --pos
				@wh_id,
				'reopenOrderRequest' 
			
			SET @unique_id_http = SCOPE_IDENTITY()
			
			--create reopen order if PO has already been sent to POD but the driver did choose to pickup the PO for whatever reason 
			--BEW 202220524
			SELECT @reopen_xml = 
				(	SELECT TOP 1 
						@unique_id_http as "@transactionId",
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
						@system_name as systemName,
						#po.po_number as orderNumber,
						#po.stop_id as expectedSequence,
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as expectedStart,
						FORMAT(DATEADD(dd, 1, GETDATE()),'yyyy-MM-ddTHH:mm:ss.fffzzz') as expectedEnd,
						@pod_whse as centerNumber,
						@route as routeNumber
					FROM #po WITH (NOLOCK)
					WHERE #po.po_number = @po_number
					--AND #po.wh_id = @wh_id --need to be scac code?? BEW 
					FOR XML PATH('reopenOrderRequest'), TYPE
				)

				UPDATE t_pod_queue_http
				SET message_xml = @reopen_xml,
					queue_status = 0
				WHERE unique_id = @unique_id_http

				--Create a record in the http queue table
				INSERT INTO t_pod_queue_http
				(	load_id,
					order_number,
					wh_id,
					message_type )
				SELECT
					@load_id,
					@po_number, --pos	
					@wh_id,
					'updateOrderAndCustomerRequest'

				SET @unique_id_http = SCOPE_IDENTITY()		
				--BEW 20220524 GENERATE XML FOR backhaul POs 
		SELECT @po_xml = --@po_xml
			(	SELECT top 1 
					@unique_id_http as "@transactionId",
					FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
					@system_name as systemName,
					@pod_whse as centerNumber,
					@route as routeNumber,
					(	SELECT
							'false' as "@mailConfirmationRequired",
							v.vendor_code as customerNumber,
							v.vendor_name as customerName,
							--1 as backhaulOrder, --BEW 20220601
							--c.chain_name as chainName, --BEW 20210331 
							'true' as printReceipt
						FOR XML PATH('customer'), TYPE
					),
					(	SELECT
							pom.ship_from_addr1 as addressLine1,
							pom.ship_from_addr2 as addressLine2,
							pom.ship_from_city as city,
							ISNULL(pom.ship_from_state, 'WA') as [state], --BEW add to PO header 
							pom.ship_from_postal_code as zipCode,
							'USA' as country
						FOR XML PATH('customerAddress'), TYPE
					),
					(	SELECT
							ISNULL(v.vendor_name, 'HARBOR') as firstName,
							ISNULL(v.vendor_name, 'HARBOR') as lastName,
							LEFT(pom.ship_from_addr1, 30) as [location],
							'true' as active
						FOR XML PATH('contact'), TYPE
					),
					(	SELECT
							CONCAT(po.stop_id, @route) as groupNumber,	
						(	
							SELECT
								'goods' as "@typeName",
								'an order that consists of goods' as "@typeDescription",
								'false' as "@canceled",
								pom.po_number as orderNumber,
								pom.create_date as orderDate, --use another date? BEW 
								CASE WHEN ISNULL(pom.po_number, '') <> '' THEN pom.po_number END as poNumber,
								FORMAT(pom.expected_receipt_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
								FORMAT(pom.expected_receipt_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
								po.stop_id as expectedServiceSequence,
								'0' as expectedPayment,
								'false' as backOrder, 
								'false' as acceptAll,
								'Highjump WMS POD Interface' as serviceInstructions,
								'false' as sendWireless,
								'false' as scheduledEmpty,
								0 as expectedItemQuantity,
								'true' as authorizedSignerRequired,
								
								(	
								
									SELECT 
										[@typeName],
										[@typeDescription],
										[@purposeNumber],
										lineNumber,
										[description],
										orderedQuantity,
										fulfilledQuantity,
										serviceQuantity,
										--0[gs1Number/@type],
										--0gs1Number,
										--0[property/@name],
										--0[property/@description],
										--0[property/@dataType],
										--0property, --BEW 20211206								
										identification
									FROM
									(
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											'pickup' as "@purposeNumber", --backhaul code in descartes
											pod.line_number  as lineNumber, --needs to be unique 
											im.[description] as [description],
											cast(SUM(pod.qty) as INT) as orderedQuantity, --sum
											0 as fulfilledQuantity,
											cast(SUM(pod.qty) as int) as serviceQuantity, --sum,
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													pod.item_number as identificationNumber,
													im.[description] as [name],
													im.[description] as [description],
													(	SELECT
															pod.order_uom as 'abbreviation',
															pod.order_uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_po_detail pod WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON pod.item_number = im.item_number
											AND pod.wh_id = im.wh_id			
										INNER JOIN #po po 
											ON pod.line_number = po.line_number
											AND pod.po_number = po.po_number
											--AND pod.wh_id = po.wh_id 		--BEW 20220620 				
										WHERE pom.po_number = pod.po_number
										AND pom.wh_id = pod.wh_id -- BEW USE SCAC?>
										AND
										(	pod.order_uom = 'CS'
											--AND ISNULL(c.gln, '') <> ''
											AND EXISTS (SELECT 1 FROM t_item_upc u WITH (NOLOCK) WHERE u.item_number = pod.item_number AND u.wh_id = pod.wh_id AND u.uom = 'CS' AND LEN(upc) BETWEEN 12 and 14) 	
										)
										GROUP BY
											pod.wh_id,
											im.class_id,
											pod.item_number,
											pod.line_number,
											im.[description],
											pod.qty,
											pod.order_uom,
											pod.po_number
											--hs.gs1_required_flag,
											--im.net_weight_barcode --BEW 20211206
										UNION ALL
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											'pickup' as "@purposeNumber", -- descartes code for backhaul 
											pod.line_number as lineNumber,
											im.[description] as [description],
											cast(SUM(pod.qty) as int) as orderedQuantity, --cast int 
											0 as fulfilledQuantity,
											cast(SUM(pod.qty) as int) as serviceQuantity, --SUM 
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													pod.item_number as identificationNumber,
													im.[description] as [name],
													im.[description] as [description],
													(	SELECT
															pod.order_uom as 'abbreviation',
															pod.order_uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_po_detail pod WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON pod.item_number = im.item_number
											AND pod.wh_id = im.wh_id			
										INNER JOIN #po po
											ON pod.line_number = po.line_number
											AND pod.po_number = po.po_number
											--AND pod.wh_id = po.wh_id		--BEW 20220620				
										WHERE pom.po_number = pod.po_number
										AND pom.wh_id = pod.wh_id
										AND NOT
										(	pod.order_uom = 'CS'
											--AND ISNULL(c.gln, '') <> ''
											AND EXISTS (SELECT 1 FROM t_item_upc u WITH (NOLOCK) WHERE u.item_number = pod.item_number AND u.wh_id = pod.wh_id AND u.uom = 'CS' AND LEN(upc) BETWEEN 12 and 14)
										) 
										GROUP BY
											pod.wh_id,
											im.class_id,
											pod.item_number,
											pod.line_number,
											im.[description],
											pod.qty,
											pod.order_uom,  
											pod.po_number
											--im.net_weight_barcode --BEW 20211206 
									) as t
									FOR XML PATH('orderItem'), TYPE
								)
							FOR XML PATH('order'), TYPE
						)
					FOR XML PATH('orders'), TYPE
				)
				FROM t_po_master pom WITH (NOLOCK) 
				INNER JOIN t_vendor v WITH (NOLOCK)
					ON pom.vendor_code = v.vendor_code
				INNER JOIN #po po 
					ON pom.po_number = po.po_number
					--AND pom.wh_id = po.wh_id --BEW 2022060
				WHERE pom.po_number = @po_number
				AND pom.carrier_scac= @wh_id -- BEW TESTING 
				FOR XML PATH('updateOrderAndCustomerRequest'), TYPE
			)
			--Updates tatus to iundicate PO has been resent
			--BEW 20220629
			UPDATE t_po_backhaul_airclic 
			SET [status] = 'SENT'
			WHERE po_number = @po_number 

			END
			ELSE 
			BEGIN 
				--Create a record in the http queue table
				INSERT INTO t_pod_queue_http
				(	load_id,
					order_number,
					wh_id,
					message_type )
				SELECT
					@load_id,
					@po_number,
					@wh_id,
					'addOrderAndCustomerRequest'

				SET @unique_id_http = SCOPE_IDENTITY()

					--po xml here 
			SELECT @po_xml = --@po_xml
			(	SELECT top 1 
					@unique_id_http as "@transactionId",
					FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
					@system_name as systemName,
					@pod_whse as centerNumber,
					@route as routeNumber,
					(	SELECT
							'false' as "@mailConfirmationRequired",
							v.vendor_code as customerNumber,
							v.vendor_name as customerName,
							--1 as backhaulOrder, --BEW 20220601
							--c.chain_name as chainName, --BEW 20210331 
							'true' as printReceipt
						FOR XML PATH('customer'), TYPE
					),
					(	SELECT
							pom.ship_from_addr1 as addressLine1,
							pom.ship_from_addr2 as addressLine2,
							pom.ship_from_city as city,
							ISNULL(pom.ship_from_state, 'WA')  as state, --bew add to PO int
							pom.ship_from_postal_code as zipCode,
							'USA' as country
						FOR XML PATH('customerAddress'), TYPE
					),
					(	SELECT
							ISNULL(v.vendor_name, 'HARBOR') as firstName,
							ISNULL(v.vendor_name, 'HARBOR') as lastName,
							LEFT(pom.ship_from_addr1, 30) as location,
							'true' as active
						FOR XML PATH('contact'), TYPE
					),
					(	SELECT
							CONCAT(po.stop_id, @route) as groupNumber,	
						(	
							SELECT
								'goods' as "@typeName",
								'an order that consists of goods' as "@typeDescription",
								'false' as "@canceled",
								pom.po_number as orderNumber,
								pom.create_date as orderDate, --use another date? BEW 
								CASE WHEN ISNULL(pom.po_number, '') <> '' THEN pom.po_number END as poNumber,
								FORMAT(pom.expected_receipt_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
								FORMAT(pom.expected_receipt_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
								po.stop_id as expectedServiceSequence,
								'0' as expectedPayment,
								'false' as backOrder,
								'false' as acceptAll,
								'Highjump WMS POD Interface' as serviceInstructions,
								'false' as sendWireless,
								'false' as scheduledEmpty,
								0 as expectedItemQuantity,
								'true' as authorizedSignerRequired,
								
								(	
								
									SELECT 
										[@typeName],
										[@typeDescription],
										[@purposeNumber],
										lineNumber,
										[description],
										orderedQuantity,
										fulfilledQuantity,
										serviceQuantity,
										--0[gs1Number/@type],
										--0gs1Number,
										--0[property/@name],
										--0[property/@description],
										--0[property/@dataType],
										--0property, --BEW 20211206								
										identification
									FROM
									(
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											'pickup' as "@purposeNumber", --backhaul code in descartes
											pod.line_number  as lineNumber, --needs to be unique 
											im.[description] as [description],
											cast(SUM(pod.qty) as INT) as orderedQuantity, --sum
											0 as fulfilledQuantity,
											cast(SUM(pod.qty) as int) as serviceQuantity, --sum,
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													pod.item_number as identificationNumber,
													im.[description] as [name],
													im.[description] as [description],
													(	SELECT
															pod.order_uom as 'abbreviation',
															pod.order_uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_po_detail pod WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON pod.item_number = im.item_number
											AND pod.wh_id = im.wh_id			
										INNER JOIN #po po 
											ON pod.line_number = po.line_number
											AND pod.po_number = po.po_number
										--	AND pod.wh_id = po.wh_id  -bew 20220620 						
										WHERE pom.po_number = pod.po_number
										AND pom.wh_id = pod.wh_id -- BEW USE SCAC?>
										AND
										(	pod.order_uom = 'CS'
											--AND ISNULL(c.gln, '') <> ''
											AND EXISTS (SELECT 1 FROM t_item_upc u WITH (NOLOCK) WHERE u.item_number = pod.item_number AND u.wh_id = pod.wh_id AND u.uom = 'CS' AND LEN(upc) BETWEEN 12 and 14) 	
										)
										GROUP BY
											pod.wh_id,
											im.class_id,
											pod.item_number,
											pod.line_number,
											im.[description],
											pod.qty,
											pod.order_uom,
											pod.po_number
											--hs.gs1_required_flag,
											--im.net_weight_barcode --BEW 20211206
										UNION ALL
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											'pickup' as "@purposeNumber", --backhaul code in descartes
											pod.line_number as lineNumber,
											im.[description] as [description],
											cast(SUM(pod.qty) as int) as orderedQuantity, --cast int 
											0 as fulfilledQuantity,
											cast(SUM(pod.qty) as int) as serviceQuantity, --SUM 
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													pod.item_number as identificationNumber,
													im.[description] as [name],
													im.[description] as [description],
													(	SELECT
															pod.order_uom as 'abbreviation',
															pod.order_uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_po_detail pod WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON pod.item_number = im.item_number
											AND pod.wh_id = im.wh_id			
										INNER JOIN #po po
											ON pod.line_number = po.line_number
											AND pod.po_number = po.po_number
											--AND pod.wh_id = po.wh_id	--bew 20220620					
										WHERE pom.po_number = pod.po_number
										AND pom.wh_id = pod.wh_id
										AND NOT
										(	pod.order_uom = 'CS'
											--AND ISNULL(c.gln, '') <> ''
											AND EXISTS (SELECT 1 FROM t_item_upc u WITH (NOLOCK) WHERE u.item_number = pod.item_number AND u.wh_id = pod.wh_id AND u.uom = 'CS' AND LEN(upc) BETWEEN 12 and 14)
										) 
										GROUP BY
											pod.wh_id,
											im.class_id,
											pod.item_number,
											pod.line_number,
											im.[description],
											pod.qty,
											pod.order_uom,  
											pod.po_number
											--im.net_weight_barcode --BEW 20211206 
									) as t
									FOR XML PATH('orderItem'), TYPE
								)
							FOR XML PATH('order'), TYPE
						)
					FOR XML PATH('orders'), TYPE
				)
				FROM t_po_master pom WITH (NOLOCK) 
				INNER JOIN t_vendor v WITH (NOLOCK)
					ON pom.vendor_code = v.vendor_code
				INNER JOIN #po po 
					ON pom.po_number = po.po_number
					--AND pom.wh_id = po.wh_id --bew 20220620
				WHERE pom.po_number = @po_number
				AND pom.carrier_scac =  @wh_id --BEW testing 
				FOR XML PATH('addOrderAndCustomerRequest'), TYPE
			)
		End 

		IF ISNULL(@in_debug, 0) > 0
			BEGIN
				SELECT @po_xml po_xml
			END
				UPDATE t_pod_queue_http
				SET message_xml = @po_xml,
					queue_status = 0
				WHERE unique_id = @unique_id_http

				UPDATE #po
				SET processed = 1
				WHERE po_number = @po_number
			END

			UPDATE t_pod_queue
			SET queue_status = 2,
				dt_processed = GETDATE()
			WHERE unique_id = @unique_id
			--BEW update po record in table 
			UPDATE po 
			SET sent_to_airclic = 1 
			FROM t_po_master po
			INNER JOIN #po 
				ON po.po_number = #po.po_number 
----here BEW 20220621
		WHILE EXISTS (SELECT 1 FROM #hum_sto WHERE processed = 1)
		BEGIN
			SELECT TOP 1
				@parent_hu_id = parent_hu_id,
				@pallet_desc = pallet_desc,
				@hu_id = hu_id,
				@hu_desc = hu_desc,
				@order_number = order_number,
				@order_uom = order_uom,
				@gln = gln,
				@item_number = item_number,
				@wh_id = wh_id,
				@gs1_required_flag = gs1_required_flag
			FROM #hum_sto
			WHERE processed = 1

		--If this is a GS1 coded case pick, do not send as an add pallet request
			IF @order_uom = 'CS' AND ISNULL(@gln, '') <> '' --AND ISNULL(@gs1_required_flag, 0) = 1-- (should be able to still send cases with GTIN as just cases)
			BEGIN
				IF EXISTS
				(	SELECT 1 FROM t_item_upc u WITH (NOLOCK)
					WHERE u.item_number = @item_number
					AND u.wh_id = @wh_id
					AND u.uom = 'CS'
					AND LEN(upc) BETWEEN 12 and 14 )
				BEGIN
					UPDATE #hum_sto
					SET processed = 2
					WHERE hu_id = @hu_id 

					CONTINUE
				END
			END

		--Create a record in the http queue table
			INSERT INTO t_pod_queue_http
			(	load_id,
				order_number,
				wh_id,
				message_type )
			SELECT
				@load_id,
				@order_number,
				@wh_id,
				'addPalletRequest'

			SET @unique_id_http = SCOPE_IDENTITY()

			SELECT @pallet_xml = 
			(	SELECT
					@unique_id_http as "@transactionId",
					FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
					'HARBOR' as systemName,
					(	SELECT TOP 1
							@hu_id as palletNumber,
							@hu_desc as [description],
							CASE 
								WHEN cartonization_batch_id LIKE 'TOTE%' THEN '27'
								ELSE CASE WHEN ISNULL(class_id, '') <> '' THEN
									CASE class_id 
										WHEN 'CIG' THEN '20'
										WHEN 'CLR' THEN '3'
										WHEN 'DRY' THEN '4'
										WHEN 'FRZ' THEN '6'
										WHEN 'PRO' THEN '7'
										ELSE '13' --Misc
									END
									ELSE
									CASE pick_area 
										WHEN 'CIG' THEN '20'
										WHEN 'CLR' THEN '3'
										WHEN 'DRY' THEN '4'
										WHEN 'FRZ' THEN '6'
										WHEN 'PRO' THEN '7'
										ELSE '13' --Misc
									END
								END
							END as purposeNumber,
							'Code 128' as "barcode/@typeName",
							'Code 128' as "barcode/@typeDescription",
							@hu_id as barcode,
							(	SELECT
									hs.order_number as orderNumber,
									hs.line_number as lineNumber,
									SUM(hs.quantity) as quantity
								FROM #hum_sto hs
								WHERE hu_id = @hu_id
								GROUP BY
									hs.order_number,
									hs.line_number
								FOR XML PATH('palletItem'), TYPE
							)
						FROM #hum_sto hs
						WHERE hu_id = @hu_id
						FOR XML PATH('pallet'), TYPE
					)
				FOR XML PATH('addPalletRequest'), TYPE
			)
				
			UPDATE t_pod_queue_http
			SET message_xml = @pallet_xml,
				queue_status = 0
			WHERE unique_id = @unique_id_http

			UPDATE #hum_sto
			SET processed = 2
			WHERE hu_id = @hu_id 
		END

		WHILE EXISTS (SELECT 1 FROM #rma WHERE processed = 0)
		BEGIN
			SELECT TOP 1
				@rma_number = rma_number,
				@sent_to_airclic = sent_to_airclic
			FROM #rma
			WHERE processed = 0

			DELETE #upc

			INSERT INTO #upc
			SELECT
				rmad.wh_id,
				rmad.item_number,
				upc.upc,
				ROW_NUMBER() OVER (PARTITION BY rmad.wh_id, rmad.item_number ORDER BY upc.upc DESC)
			FROM t_rma_detail rmad WITH (NOLOCK)
			INNER JOIN t_item_upc upc WITH (NOLOCK)
				ON rmad.item_number = upc.item_number
				AND rmad.wh_id = upc.wh_id
			WHERE rmad.rma_number = @rma_number
			AND rmad.wh_id = @wh_id
			GROUP BY
				rmad.wh_id,
				rmad.item_number,
				upc.upc

			DELETE #gtin

			INSERT INTO #gtin
			SELECT
				rmad.wh_id,
				rmad.line_number,
				upc.upc,
				ROW_NUMBER() OVER (PARTITION BY rmad.wh_id, rmad.line_number ORDER BY upc.upc DESC)
			FROM t_rma_master rma WITH (NOLOCK)
			INNER JOIN t_customer c WITH (NOLOCK)
				ON rma.customer_code = c.customer_code
			INNER JOIN t_rma_detail rmad WITH (NOLOCK) 
				ON rma.rma_number = rmad.rma_number
				AND rma.wh_id = rmad.wh_id
			INNER JOIN t_item_upc upc WITH (NOLOCK)
				ON rmad.item_number = upc.item_number
				AND rmad.uom = upc.uom
				AND rmad.wh_id = upc.wh_id
			WHERE rma.rma_number = @rma_number
			AND rma.wh_id = @wh_id
			AND rmad.uom = 'CS'
			AND LEN(upc.upc) BETWEEN 12 and 14
			AND ISNULL(c.gln, '') <> ''
			ORDER BY
				upc.modified_datetime DESC

			--If already sent do update request instead of add request
			IF @sent_to_airclic = 1
			BEGIN
				--Create a record in the http queue table
				INSERT INTO t_pod_queue_http
				(	load_id,
					order_number,
					wh_id,
					message_type )
				SELECT
					@load_id,
					@rma_number,
					@wh_id,
					'reopenOrderRequest'

				SET @unique_id_http = SCOPE_IDENTITY()		

				--Create reopen order request, this is necessary because if the POD user chooses not to do the RMA the first time the RMA was sent
				--the rma order will have to be reopened before it can be updated
				SELECT @reopen_xml = 
				(	SELECT
						@unique_id_http as "@transactionId",
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
						@system_name as systemName,
						#rma.rma_number as orderNumber,
						#rma.stop_id as expectedSequence,
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as expectedStart,
						FORMAT(DATEADD(dd, 1, GETDATE()),'yyyy-MM-ddTHH:mm:ss.fffzzz') as expectedEnd,
						@pod_whse as centerNumber,
						@route as routeNumber
					FROM #rma WITH (NOLOCK)
					WHERE #rma.rma_number = @rma_number
					AND #rma.wh_id = @wh_id
					FOR XML PATH('reopenOrderRequest'), TYPE
				)

				UPDATE t_pod_queue_http
				SET message_xml = @reopen_xml,
					queue_status = 0
				WHERE unique_id = @unique_id_http

				--Create a record in the http queue table
				INSERT INTO t_pod_queue_http
				(	load_id,
					order_number,
					wh_id,
					message_type )
				SELECT
					@load_id,
					@rma_number,
					@wh_id,
					'updateOrderAndCustomerRequest'

				SET @unique_id_http = SCOPE_IDENTITY()			

				SELECT @rma_xml = 
				(	SELECT
						@unique_id_http as "@transactionId",
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
						@system_name as systemName,
						@pod_whse as centerNumber,
						@route as routeNumber,
						(	SELECT
								'false' as "@mailConfirmationRequired",
								c.customer_code as customerNumber,
								c.customer_name as customerName,
								'true' as printReceipt
							FOR XML PATH('customer'), TYPE
						),
						(	SELECT
								c.customer_addr1 as addressLine1,
								c.customer_addr2 as addressLine2,
								c.customer_city as city,
								c.customer_state as [state],
								c.customer_zip as zipCode,
								'USA' as country
							FOR XML PATH('customerAddress'), TYPE
						),
						(	SELECT
								c.customer_name as firstName,
								c.customer_name as lastName,
								LEFT(c.customer_addr1, 30) as [location],
								'true' as active
							FOR XML PATH('contact'), TYPE
						),
						(	SELECT
								CONCAT(#rma.stop_id, @route) as groupNumber,	
							(	
								SELECT
									'goods' as "@typeName",
									'an order that consists of goods' as "@typeDescription",
									'false' as "@canceled",
									rma.rma_number as orderNumber,
									rma.order_date as orderDate,
									FORMAT(rma.order_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
									#rma.stop_id as expectedServiceSequence,
									'0' as expectedPayment,
									'false' as backOrder,
									'false' as acceptAll,
									'Highjump WMS POD Interface' as serviceInstructions,
									'false' as sendWireless,
									'false' as scheduledEmpty,
									0 as expectedItemQuantity,
									'PRINTPRICESIND' as "property/@name",
									'Pr Ind' as "property/@description",
									'boolean' as "property/@dataType",
									'N' as property,
									'true' as authorizedSignerRequired,
									(	
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											'Product Pickup' as "@purposeNumber",
											rmad.line_number as lineNumber,
											rmad.uom + '-' + im.[description] as [description], --BEW 20200925 added uom to description field
											CAST(rmad.qty/iu.conversion_factor AS INT) as orderedQuantity,
											CAST(ISNULL(rmad.qty_receivied, 0)/iu.conversion_factor AS INT) as fulfilledQuantity,
											CAST(rmad.qty/iu.conversion_factor AS INT) as serviceQuantity,
											--STS 20191009 - The following code is here to support putting as many UPCs as exist (up to 10) into the message
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as barcode,
											NULL,
											(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "gs1Number/@type",
											(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as gs1Number,
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													rmad.item_number as identificationNumber,
													rmad.item_number as [name],
													im.[description] as [description],
													(	SELECT
															rmad.uom as 'abbreviation',
															rmad.uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													),
													(	SELECT
															CAST(rmad.qty/iu.conversion_factor AS INT) as 'quantity',
															rmad.uom as 'description'
														FOR XML PATH('packagingInfo'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_rma_detail rmad WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON rmad.item_number = im.item_number
											AND rmad.wh_id = im.wh_id
										INNER JOIN t_item_uom iu WITH (NOLOCK)
											ON rmad.item_number = iu.item_number
											AND rmad.uom = iu.uom
											AND rmad.wh_id = iu.wh_id		
										WHERE rma.rma_number = rmad.rma_number
										AND rma.wh_id = rmad.wh_id
										AND ISNULL(rmad.qty_receivied, 0) < qty
										AND ISNULL(rmad.rcvd_by_airclic, 0) = 0
										FOR XML PATH('orderItem'), TYPE
									)
								FOR XML PATH('order'), TYPE
							)
						FOR XML PATH('orders'), TYPE
					)
					FROM #rma WITH (NOLOCK)
					INNER JOIN t_rma_master rma WITH (NOLOCK)
						ON #rma.rma_number = rma.rma_number
						AND #rma.wh_id = rma.wh_id
					INNER JOIN t_customer c WITH (NOLOCK)
						ON rma.customer_code = c.customer_code
					WHERE #rma.rma_number = @rma_number
					AND #rma.wh_id = @wh_id
					FOR XML PATH('updateOrderAndCustomerRequest'), TYPE
				)
			END
			ELSE
			BEGIN
				--Create a record in the http queue table
				INSERT INTO t_pod_queue_http
				(	load_id,
					order_number,
					wh_id,
					message_type )
				SELECT
					@load_id,
					@rma_number,
					@wh_id,
					'addOrderAndCustomerRequest'

				SET @unique_id_http = SCOPE_IDENTITY()	

				SELECT @rma_xml = 
				(	SELECT
						@unique_id_http as "@transactionId",
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
						@system_name as systemName,
						@pod_whse as centerNumber,
						@route as routeNumber,
						(	SELECT
								'false' as "@mailConfirmationRequired",
								c.customer_code as customerNumber,
								c.customer_name as customerName,
								'true' as printReceipt
							FOR XML PATH('customer'), TYPE
						),
						(	SELECT
								c.customer_addr1 as addressLine1,
								c.customer_addr2 as addressLine2,
								c.customer_city as city,
								c.customer_state as [state],
								c.customer_zip as zipCode,
								'USA' as country
							FOR XML PATH('customerAddress'), TYPE
						),
						(	SELECT
								c.customer_name as firstName,
								c.customer_name as lastName,
								LEFT(c.customer_addr1, 30) as location,
								'true' as active
							FOR XML PATH('contact'), TYPE
						),
						(	SELECT
								CONCAT(#rma.stop_id, @route) as groupNumber,	
							(	
								SELECT
									'goods' as "@typeName",
									'an order that consists of goods' as "@typeDescription",
									'false' as "@canceled",
									rma.rma_number as orderNumber,
									rma.order_date as orderDate,
									FORMAT(rma.order_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
									#rma.stop_id as expectedServiceSequence,
									'0' as expectedPayment,
									'false' as backOrder,
									'false' as acceptAll,
									'Highjump WMS POD Interface' as serviceInstructions,
									'false' as sendWireless,
									'false' as scheduledEmpty,
									0 as expectedItemQuantity,
									'PRINTPRICESIND' as "property/@name",
									'Pr Ind' as "property/@description",
									'boolean' as "property/@dataType",
									'N' as property,
									'true' as authorizedSignerRequired,
									(	
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											'Product Pickup' as "@purposeNumber",
											rmad.line_number as lineNumber,
											rmad.uom + '-' + im.[description] as [description], --BEW 20200925 added uom to description field
											CAST(rmad.qty/iu.conversion_factor AS INT) as orderedQuantity,
											CAST(ISNULL(rmad.qty_receivied, 0)/iu.conversion_factor AS INT) as fulfilledQuantity,
											CAST(rmad.qty/iu.conversion_factor AS INT) as serviceQuantity,
											--STS 20191009 - The following code is here to support putting as many UPCs as exist (up to 10) into the message
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as barcode,
											NULL,
											(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "gs1Number/@type",
											(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as gs1Number,
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													rmad.item_number as identificationNumber,
													rmad.item_number as [name],
													im.[description] as [description],
													(	SELECT
															rmad.uom as 'abbreviation',
															rmad.uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													),
													(	SELECT
															CAST(rmad.qty/iu.conversion_factor AS INT) as 'quantity',
															rmad.uom as 'description'
														FOR XML PATH('packagingInfo'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_rma_detail rmad WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON rmad.item_number = im.item_number
											AND rmad.wh_id = im.wh_id		
										INNER JOIN t_item_uom iu WITH (NOLOCK)
											ON rmad.item_number = iu.item_number
											AND rmad.uom = iu.uom
											AND rmad.wh_id = iu.wh_id
										WHERE rma.rma_number = rmad.rma_number
										AND rma.wh_id = rmad.wh_id
										AND ISNULL(rmad.qty_receivied, 0) < qty
										AND ISNULL(rmad.rcvd_by_airclic, 0) = 0
										FOR XML PATH('orderItem'), TYPE
									)
								FOR XML PATH('order'), TYPE
							)
						FOR XML PATH('orders'), TYPE
					)
					FROM #rma WITH (NOLOCK)
					INNER JOIN t_rma_master rma WITH (NOLOCK)
						ON #rma.rma_number = rma.rma_number
						AND #rma.wh_id = rma.wh_id
					INNER JOIN t_customer c WITH (NOLOCK)
						ON rma.customer_code = c.customer_code
					WHERE #rma.rma_number = @rma_number
					AND #rma.wh_id = @wh_id
					FOR XML PATH('addOrderAndCustomerRequest'), TYPE
				)
			END
/** BEW 20220617 - Begin comment out RMA logic
	WHILE EXISTS (SELECT 1 FROM #rma WHERE processed = 0)
		BEGIN
			SELECT TOP 1
				@rma_number = rma_number,
				@sent_to_airclic = sent_to_airclic
			FROM #rma
			WHERE processed = 0

			DELETE #upc

			INSERT INTO #upc
			SELECT
				rmad.wh_id,
				rmad.item_number,
				upc.upc,
				ROW_NUMBER() OVER (PARTITION BY rmad.wh_id, rmad.item_number ORDER BY upc.upc DESC)
			FROM t_rma_detail rmad WITH (NOLOCK)
			INNER JOIN t_item_upc upc WITH (NOLOCK)
				ON rmad.item_number = upc.item_number
				AND rmad.wh_id = upc.wh_id
			WHERE rmad.rma_number = @rma_number
			AND rmad.wh_id = @wh_id
			GROUP BY
				rmad.wh_id,
				rmad.item_number,
				upc.upc

			DELETE #gtin

			INSERT INTO #gtin
			SELECT
				rmad.wh_id,
				rmad.line_number,
				upc.upc,
				ROW_NUMBER() OVER (PARTITION BY rmad.wh_id, rmad.line_number ORDER BY upc.upc DESC)
			FROM t_rma_master rma WITH (NOLOCK)
			INNER JOIN t_customer c WITH (NOLOCK)
				ON rma.customer_code = c.customer_code
			INNER JOIN t_rma_detail rmad WITH (NOLOCK) 
				ON rma.rma_number = rmad.rma_number
				AND rma.wh_id = rmad.wh_id
			INNER JOIN t_item_upc upc WITH (NOLOCK)
				ON rmad.item_number = upc.item_number
				AND rmad.uom = upc.uom
				AND rmad.wh_id = upc.wh_id
			WHERE rma.rma_number = @rma_number
			AND rma.wh_id = @wh_id
			AND rmad.uom = 'CS'
			AND LEN(upc.upc) BETWEEN 12 and 14
			AND ISNULL(c.gln, '') <> ''
			ORDER BY
				upc.modified_datetime DESC

			--If already sent do update request instead of add request
			IF @sent_to_airclic = 1
			BEGIN
				--Create a record in the http queue table
				INSERT INTO t_pod_queue_http
				(	load_id,
					order_number,
					wh_id,
					message_type )
				SELECT
					@load_id,
					@rma_number,
					@wh_id,
					'reopenOrderRequest'

				SET @unique_id_http = SCOPE_IDENTITY()		

				--Create reopen order request, this is necessary because if the POD user chooses not to do the RMA the first time the RMA was sent
				--the rma order will have to be reopened before it can be updated
				SELECT @reopen_xml = 
				(	SELECT
						@unique_id_http as "@transactionId",
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
						@system_name as systemName,
						#rma.rma_number as orderNumber,
						#rma.stop_id as expectedSequence,
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as expectedStart,
						FORMAT(DATEADD(dd, 1, GETDATE()),'yyyy-MM-ddTHH:mm:ss.fffzzz') as expectedEnd,
						@pod_whse as centerNumber,
						@route as routeNumber
					FROM #rma WITH (NOLOCK)
					WHERE #rma.rma_number = @rma_number
					AND #rma.wh_id = @wh_id
					FOR XML PATH('reopenOrderRequest'), TYPE
				)

				UPDATE t_pod_queue_http
				SET message_xml = @reopen_xml,
					queue_status = 0
				WHERE unique_id = @unique_id_http

				--Create a record in the http queue table
				INSERT INTO t_pod_queue_http
				(	load_id,
					order_number,
					wh_id,
					message_type )
				SELECT
					@load_id,
					@rma_number,
					@wh_id,
					'updateOrderAndCustomerRequest'

				SET @unique_id_http = SCOPE_IDENTITY()			

				SELECT @rma_xml = 
				(	SELECT
						@unique_id_http as "@transactionId",
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
						@system_name as systemName,
						@pod_whse as centerNumber,
						@route as routeNumber,
						(	SELECT
								'false' as "@mailConfirmationRequired",
								c.customer_code as customerNumber,
								c.customer_name as customerName,
								'true' as printReceipt
							FOR XML PATH('customer'), TYPE
						),
						(	SELECT
								c.customer_addr1 as addressLine1,
								c.customer_addr2 as addressLine2,
								c.customer_city as city,
								c.customer_state as state,
								c.customer_zip as zipCode,
								'USA' as country
							FOR XML PATH('customerAddress'), TYPE
						),
						(	SELECT
								c.customer_name as firstName,
								c.customer_name as lastName,
								LEFT(c.customer_addr1, 30) as location,
								'true' as active
							FOR XML PATH('contact'), TYPE
						),
						(	SELECT
								CONCAT(#rma.stop_id, @route) as groupNumber,	
							(	
								SELECT
									'goods' as "@typeName",
									'an order that consists of goods' as "@typeDescription",
									'false' as "@canceled",
									rma.rma_number as orderNumber,
									rma.order_date as orderDate,
									FORMAT(rma.order_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
									#rma.stop_id as expectedServiceSequence,
									'0' as expectedPayment,
									'false' as backOrder,
									'false' as acceptAll,
									'Highjump WMS POD Interface' as serviceInstructions,
									'false' as sendWireless,
									'false' as scheduledEmpty,
									0 as expectedItemQuantity,
									'PRINTPRICESIND' as "property/@name",
									'Pr Ind' as "property/@description",
									'boolean' as "property/@dataType",
									'N' as property,
									'true' as authorizedSignerRequired,
									(	
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											'Product Pickup' as "@purposeNumber",
											rmad.line_number as lineNumber,
											rmad.uom +'-'+im.description as description, --BEW 20200925 added uom to description field
											CAST(rmad.qty/iu.conversion_factor AS INT) as orderedQuantity,
											CAST(ISNULL(rmad.qty_receivied, 0)/iu.conversion_factor AS INT) as fulfilledQuantity,
											CAST(rmad.qty/iu.conversion_factor AS INT) as serviceQuantity,
											--STS 20191009 - The following code is here to support putting as many UPCs as exist (up to 10) into the message
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as barcode,
											NULL,
											(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "gs1Number/@type",
											(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as gs1Number,
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													rmad.item_number as identificationNumber,
													rmad.item_number as name,
													im.description as description,
													(	SELECT
															rmad.uom as 'abbreviation',
															rmad.uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													),
													(	SELECT
															CAST(rmad.qty/iu.conversion_factor AS INT) as 'quantity',
															rmad.uom as 'description'
														FOR XML PATH('packagingInfo'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_rma_detail rmad WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON rmad.item_number = im.item_number
											AND rmad.wh_id = im.wh_id
										INNER JOIN t_item_uom iu WITH (NOLOCK)
											ON rmad.item_number = iu.item_number
											AND rmad.uom = iu.uom
											AND rmad.wh_id = iu.wh_id		
										WHERE rma.rma_number = rmad.rma_number
										AND rma.wh_id = rmad.wh_id
										AND ISNULL(rmad.qty_receivied, 0) < qty
										AND ISNULL(rmad.rcvd_by_airclic, 0) = 0
										FOR XML PATH('orderItem'), TYPE
									)
								FOR XML PATH('order'), TYPE
							)
						FOR XML PATH('orders'), TYPE
					)
					FROM #rma WITH (NOLOCK)
					INNER JOIN t_rma_master rma WITH (NOLOCK)
						ON #rma.rma_number = rma.rma_number
						AND #rma.wh_id = rma.wh_id
					INNER JOIN t_customer c WITH (NOLOCK)
						ON rma.customer_code = c.customer_code
					WHERE #rma.rma_number = @rma_number
					AND #rma.wh_id = @wh_id
					FOR XML PATH('updateOrderAndCustomerRequest'), TYPE
				)
			END
			ELSE
			BEGIN
				--Create a record in the http queue table
				INSERT INTO t_pod_queue_http
				(	load_id,
					order_number,
					wh_id,
					message_type )
				SELECT
					@load_id,
					@rma_number,
					@wh_id,
					'addOrderAndCustomerRequest'

				SET @unique_id_http = SCOPE_IDENTITY()	

				SELECT @rma_xml = 
				(	SELECT
						@unique_id_http as "@transactionId",
						FORMAT(GETDATE(),'yyyy-MM-ddTHH:mm:ss.fffzzz') as "@timestamp",
						@system_name as systemName,
						@pod_whse as centerNumber,
						@route as routeNumber,
						(	SELECT
								'false' as "@mailConfirmationRequired",
								c.customer_code as customerNumber,
								c.customer_name as customerName,
								'true' as printReceipt
							FOR XML PATH('customer'), TYPE
						),
						(	SELECT
								c.customer_addr1 as addressLine1,
								c.customer_addr2 as addressLine2,
								c.customer_city as city,
								c.customer_state as state,
								c.customer_zip as zipCode,
								'USA' as country
							FOR XML PATH('customerAddress'), TYPE
						),
						(	SELECT
								c.customer_name as firstName,
								c.customer_name as lastName,
								LEFT(c.customer_addr1, 30) as location,
								'true' as active
							FOR XML PATH('contact'), TYPE
						),
						(	SELECT
								CONCAT(#rma.stop_id, @route) as groupNumber,	
							(	
								SELECT
									'goods' as "@typeName",
									'an order that consists of goods' as "@typeDescription",
									'false' as "@canceled",
									rma.rma_number as orderNumber,
									rma.order_date as orderDate,
									FORMAT(rma.order_date,'yyyy-MM-ddTHH:mm:ss.fffzzz') as serviceWindowStart,
									#rma.stop_id as expectedServiceSequence,
									'0' as expectedPayment,
									'false' as backOrder,
									'false' as acceptAll,
									'Highjump WMS POD Interface' as serviceInstructions,
									'false' as sendWireless,
									'false' as scheduledEmpty,
									0 as expectedItemQuantity,
									'PRINTPRICESIND' as "property/@name",
									'Pr Ind' as "property/@description",
									'boolean' as "property/@dataType",
									'N' as property,
									'true' as authorizedSignerRequired,
									(	
										SELECT
											'item' as "@typeName",
											im.class_id as "@typeDescription",
											'Product Pickup' as "@purposeNumber",
											rmad.line_number as lineNumber,
											rmad.uom + '-'+ im.description as description, --BEW 20200925 added uom to description field
											CAST(rmad.qty/iu.conversion_factor AS INT) as orderedQuantity,
											CAST(ISNULL(rmad.qty_receivied, 0)/iu.conversion_factor AS INT) as fulfilledQuantity,
											CAST(rmad.qty/iu.conversion_factor AS INT) as serviceQuantity,
											--STS 20191009 - The following code is here to support putting as many UPCs as exist (up to 10) into the message
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 6) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 7) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 8) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 9) as barcode,
											NULL,
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as "barcode/@typeName",
											(SELECT 'upc' FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as "barcode/@typeDescription",
											(SELECT upc   FROM #upc t WHERE t.item_number = rmad.item_number AND t.wh_id = rmad.wh_id AND t.rownum = 10) as barcode,
											NULL,
											(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as "gs1Number/@type",
											(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 1) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 2) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 3) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 4) as gs1Number,
											--NULL,
											--(SELECT 'GTIN' FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as "gs1Number/@type",
											--(SELECT upc    FROM #gtin t WHERE t.line_number = rmad.line_number AND t.wh_id = rmad.wh_id AND t.rownum = 5) as gs1Number,
											(	SELECT
													'SKU' as "identificationNumber/@typeName",
													'SKU Description' as "identificationNumber/@typeDescription",
													rmad.item_number as identificationNumber,
													rmad.item_number as name,
													im.description as description,
													(	SELECT
															rmad.uom as 'abbreviation',
															rmad.uom as 'description'
														FOR XML PATH('unitOfMeasure'), TYPE
													),
													(	SELECT
															CAST(rmad.qty/iu.conversion_factor AS INT) as 'quantity',
															rmad.uom as 'description'
														FOR XML PATH('packagingInfo'), TYPE
													)
												FOR XML PATH(''), TYPE
											) as identification
										FROM t_rma_detail rmad WITH (NOLOCK)
										INNER JOIN t_item_master im WITH (NOLOCK)
											ON rmad.item_number = im.item_number
											AND rmad.wh_id = im.wh_id		
										INNER JOIN t_item_uom iu WITH (NOLOCK)
											ON rmad.item_number = iu.item_number
											AND rmad.uom = iu.uom
											AND rmad.wh_id = iu.wh_id
										WHERE rma.rma_number = rmad.rma_number
										AND rma.wh_id = rmad.wh_id
										AND ISNULL(rmad.qty_receivied, 0) < qty
										AND ISNULL(rmad.rcvd_by_airclic, 0) = 0
										FOR XML PATH('orderItem'), TYPE
									)
								FOR XML PATH('order'), TYPE
							)
						FOR XML PATH('orders'), TYPE
					)
					FROM #rma WITH (NOLOCK)
					INNER JOIN t_rma_master rma WITH (NOLOCK)
						ON #rma.rma_number = rma.rma_number
						AND #rma.wh_id = rma.wh_id
					INNER JOIN t_customer c WITH (NOLOCK)
						ON rma.customer_code = c.customer_code
					WHERE #rma.rma_number = @rma_number
					AND #rma.wh_id = @wh_id
					FOR XML PATH('addOrderAndCustomerRequest'), TYPE
				)
			END

		END	
BEW 20220617 - End Comment out RMA Logic*/ 

			UPDATE t_pod_queue_http
			SET message_xml = @rma_xml,
				queue_status = 0
			WHERE unique_id = @unique_id_http

		--10.0 Begin 
			--Reset tobacco values 
			SET @cig_count = 0 
			SET @lil_cig_count = 0 
			SET @ecig_count = 0 
			SET @snuff_count = 0 
		--10.0 End 

			UPDATE #rma
			SET processed = 1
			WHERE rma_number = @rma_number
		END

		UPDATE t_pod_queue
		SET queue_status = 2,
			dt_processed = GETDATE()
		WHERE unique_id = @unique_id

		--BEW 20211206 commented out, moving tote tracking to prod
		-- customer returns not ready for prod
		--UPDATE rma
		--SET sent_to_airclic = 1
		--FROM t_rma_master rma
		--INNER JOIN #rma
		--	ON rma.rma_number = #rma.rma_number
		--	AND rma.wh_id = #rma.wh_id
	
		
	END 
END TRY 
BEGIN CATCH
	
	--On error rollback transaction and bail out
	IF @@TRANCOUNT > 0
		ROLLBACK TRAN
	
	DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorSeverity INT;
    DECLARE @ErrorState INT;

    SELECT 
        @ErrorMessage = ERROR_MESSAGE(),
        @ErrorSeverity = ERROR_SEVERITY(),
        @ErrorState = ERROR_STATE();

    -- Use RAISERROR inside the CATCH block to return error
    -- information about the original error that caused
    -- execution to jump to the CATCH block.
    -- Doing this so the job will fail, and someone can be notified
    RAISERROR (@ErrorMessage, -- Message text.
               @ErrorSeverity, -- Severity.
               @ErrorState -- State.
               );
	
END CATCH

END




GO


