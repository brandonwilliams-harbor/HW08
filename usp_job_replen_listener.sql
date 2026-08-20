USE [AAD]
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO







ALTER PROCEDURE [dbo].[usp_job_replen_listener]
	@in_debug INT = 0
AS

BEGIN

SET NOCOUNT ON;



/****************************************************************************************************************************************************************************************
 Object: [usp_ww_rpl_replenishments]
 Description: Replen report page 1765

ChangeLog:

  Version	Date		Intials		Repo    Notes
  -------	--------	-------		------  -----------------------------------------------
  1.0		20170511    STS                 Created
  2.0       20171213    KNC                 Updated logic to set repeln uom to be highest uom regardless of if its sellable or not just needs to be an active UOM
  3.0       20180308    STS                 Many changes to handle new/updated priorities
  4.0       20180920    STS                 Changes to handle variant code on t_fwd_pick (WA cig changes)
  5.0       20190702    STS                 Add quantity in transit from build replen pallet
  6.0       20260820    BEW-HWF             modified logic for creating priorty 55 & 60 replens when only one case in overstock 

-------------------TEST SCRIPTS-----------------------------------
EXEC usp_job_replen_listener 1
*****************************************************************************************************************************************************************************************/

CREATE TABLE #replens
(
	r_id INT IDENTITY(1,1) PRIMARY KEY NONCLUSTERED,
	wh_id NVARCHAR(10),
	location_id NVARCHAR(50),
	item_number NVARCHAR(30),
	fpk_uom NVARCHAR(10),
	fpk_conversion_factor INT,
	actual_qty INT,
	qty_in_transit INT,
	min_qty INT,
	max_qty INT,
	tolerance INT,
	variant_code NVARCHAR(30),
	is_dynamic INT,
	preferred_overstock_aisle NVARCHAR(10),
	replen_area NVARCHAR(10),
	replen_uom NVARCHAR(10),
	replen_conversion_factor INT,
	needs_replen TINYINT,
	single_replen_flag TINYINT,
	single_replen_unique_id INT
)

CREATE NONCLUSTERED INDEX i_r_index1 ON #replens
(
	wh_id,
	item_number,
	fpk_uom,
	needs_replen,
	variant_code,
	actual_qty
)
INCLUDE
(
	r_id,
	location_id,
	preferred_overstock_aisle,
	max_qty,
	replen_area,
	is_dynamic,
	replen_uom,
	replen_conversion_factor,
	fpk_conversion_factor,
	min_qty,
	single_replen_flag,
	single_replen_unique_id
)

CREATE NONCLUSTERED INDEX i_r_needs_replen ON #replens
(
	needs_replen
)

CREATE NONCLUSTERED INDEX i_r_is_dynamic ON #replens
(
	is_dynamic
)


CREATE TABLE #overstock
(
	o_id INT IDENTITY(1,1) PRIMARY KEY NONCLUSTERED,
	wh_id NVARCHAR(10),
	location_id NVARCHAR(50),
	item_number NVARCHAR(30),
	variant_code NVARCHAR(30),
	actual_qty INT,
	fifo_date DATETIME,
	expiration_date DATETIME,
	aisle NVARCHAR(10),
	replen_area NVARCHAR(10)
)

CREATE NONCLUSTERED INDEX i_o_wh_loc_itm ON #overstock
(
	wh_id,
	item_number,
	variant_code,
	actual_qty
)
INCLUDE (o_id, location_id, replen_area)

CREATE NONCLUSTERED INDEX i_o_dt_aisle_qty ON #overstock
(
	expiration_date,
	fifo_date,
	aisle,
	actual_qty
)

CREATE TABLE #replens_to_create
(
	wh_id NVARCHAR(10),
	location_id NVARCHAR(50),
	from_location_id NVARCHAR(50),
	item_number NVARCHAR(30),
	qty INT,
	work_type NVARCHAR(2),
	sub_work_type NVARCHAR(2),
	replen_area NVARCHAR(10),
	priority NVARCHAR(30),
	uom NVARCHAR(10),
	pick_ref_number NVARCHAR(30)
)

CREATE TABLE #order_demand
(
	wh_id NVARCHAR(10),
	order_number NVARCHAR(30),
	line_number NVARCHAR(10),
	item_number NVARCHAR(30),
	qty INT,
	uom NVARCHAR(10),
	variant_code NVARCHAR(30),
	mixed_allowed TINYINT,
	fpk_uom NVARCHAR(10),
	status NVARCHAR(10),
	processed TINYINT
)

CREATE NONCLUSTERED INDEX i_od_wh_item_uom ON #order_demand
(
	wh_id,
	item_number,
	uom
)

CREATE NONCLUSTERED INDEX i_od_wh_ord_line ON #order_demand
(
	wh_id,
	order_number,
	line_number
)

CREATE NONCLUSTERED INDEX i_od_wh_ord_line_itm ON #order_demand
(
	wh_id,
	order_number,
	line_number,
	item_number
)

CREATE NONCLUSTERED INDEX i_od_wh_itm_uom ON #order_demand
(
	processed,
	wh_id,
	item_number,
	fpk_uom,
	variant_code
)
INCLUDE (status, order_number, line_number)

CREATE NONCLUSTERED INDEX i_od_processed_covered ON #order_demand
(processed) INCLUDE (wh_id, item_number, fpk_uom, qty, status, variant_code)


CREATE NONCLUSTERED INDEX i_od_index1 ON #order_demand
(processed, wh_id, item_number, fpk_uom, variant_code, status)

DECLARE
	@r_id INT = 0,
	@r_wh NVARCHAR(10),
	@r_loc NVARCHAR(50),
	@r_item NVARCHAR(30),
	@r_aisle NVARCHAR(10),
	@r_uom NVARCHAR(10),
	@r_conv INT,
	@o_id INT = 0,
	@o_wh NVARCHAR(10),
	@o_loc NVARCHAR(50),
	@o_item NVARCHAR(30),
	@o_qty INT,
	@o_uom NVARCHAR(10),
	@o_replen_area NVARCHAR(10),
	@fpk_uom NVARCHAR(10),
	@fpk_conv INT,
	@needed_qty INT,
	@avail_qty INT,
	@demand_qty INT,
	@released_qty INT,
	@unreleased_qty INT,
	@replen_qty INT,
	@replen_area NVARCHAR(10),
	@more_to_process INT = 1,
	@is_dynamic INT,
	@wh_cnt INT,
	@order_number NVARCHAR(30),
	@line_number NVARCHAR(10),
	@order_status NVARCHAR(20),
	@opk_qty INT,
	@opk_loc NVARCHAR(50),
	@opk_demand_qty INT,
	@opk_uom NVARCHAR(10),
	@opk_replen_area NVARCHAR(10),
	@outchaser_released_qty INT,
	@outchaser_unreleased_qty INT,
	@below_min INT,
	@variant_code NVARCHAR(30),
	@single_replen_flag TINYINT,
	@single_replen_unique_id INT

BEGIN TRY

	UPDATE dsrq
	SET status = 'C'
	FROM t_dynamic_single_replen_queue dsrq
	WHERE dsrq.status = 'P'
	AND NOT EXISTS
	(	SELECT 1
		FROM t_work_q q WITH (NOLOCK)
		WHERE q.pick_ref_number = CONVERT(NVARCHAR(30), dsrq.unique_id)
		AND q.work_type = '22'
		AND q.work_status <> 'C'
	)

	--Get locations that are less than the maximum
	INSERT INTO #replens
	SELECT
		fpk.wh_id,
		fpk.location_id,
		fpk.item_number,
		fpk.uom,
		iu.conversion_factor,
		SUM(ISNULL(sto.actual_qty, 0)),
		0, --qty_in_transit, update later
		fpk.minimum_trigger_qty * ISNULL(iu.conversion_factor, 1),
		fpk.maximum_replenishment_qty * ISNULL(iu.conversion_factor, 1),
		fpk.tolerance_percent,
		fpk.variant_code,
		loc.is_dynamic,
		loc.preferred_overstock_aisle,
		loc.replen_area,
		iu.uom,
		iu.conversion_factor,
		CASE WHEN SUM(ISNULL(sto.actual_qty, 0)) < (fpk.maximum_replenishment_qty * ISNULL(iu.conversion_factor, 1)) THEN 1 ELSE 0 END as needs_replen,
		ISNULL(fpk.single_replen_flag, 0),
		q.unique_id
	FROM t_fwd_pick fpk WITH (NOLOCK)
	INNER JOIN t_item_uom iu WITH (NOLOCK)
		ON fpk.item_number = iu.item_number
		AND fpk.uom = iu.uom
		AND fpk.wh_id = iu.wh_id
	LEFT OUTER JOIN t_stored_item sto WITH (NOLOCK)
		ON fpk.location_id = sto.location_id
		AND fpk.item_number = sto.item_number
		AND fpk.wh_id = sto.wh_id
	INNER JOIN t_location loc WITH (NOLOCK)
		ON fpk.location_id = loc.location_id
		AND fpk.wh_id = loc.wh_id
	LEFT OUTER JOIN t_dynamic_single_replen_queue q WITH (NOLOCK)
		ON fpk.location_id = q.location_id
		AND fpk.wh_id = q.wh_id
		AND fpk.uom = q.uom
		AND fpk.item_number = q.item_number
	WHERE
	(	ISNULL(fpk.single_replen_flag,0) <> 1
		OR
		( fpk.single_replen_flag = 1 AND q.unique_id IS NOT NULL AND q.status <> 'C')
	)
	GROUP BY
		fpk.wh_id,
		fpk.location_id,
		fpk.item_number,
		fpk.uom,
		fpk.minimum_trigger_qty,
		fpk.maximum_replenishment_qty,
		fpk.tolerance_percent,
		fpk.variant_code,
		loc.is_dynamic,
		loc.preferred_overstock_aisle,
		loc.replen_area,
		iu.uom,
		iu.conversion_factor,
		fpk.single_replen_flag,
		q.unique_id
	--HAVING SUM(ISNULL(sto.actual_qty, 0)) < ((fpk.maximum_replenishment_qty + fpk.minimum_trigger_qty) * ISNULL(iu.conversion_factor, 1))
	
	--STS 20180118
	--Consider inventory in transit to be replenished as inventory in location
	UPDATE r
	SET actual_qty = actual_qty + fork_qty,
		qty_in_transit = fork_qty,
		needs_replen = CASE WHEN actual_qty + fork_qty < max_qty THEN 1 ELSE 0 END
	--OUTPUT DELETED.actual_qty as before_qty, INSERTED.actual_qty as after_qty, DELETED.needs_replen as before_nr, INSERTED.needs_replen as after_nr, INSERTED.location_id, INSERTED.item_number
	FROM #replens r
	INNER JOIN
	(
		--Find inventory currently in transit to be replenished
		SELECT 
			sto.wh_id,
			sto.item_number,
			q.location_id,
			SUM(sto.actual_qty) as fork_qty
		FROM t_work_q_assignment wqa WITH (NOLOCK)
		INNER JOIN t_work_q q WITH (NOLOCK)
			ON wqa.work_q_id = q.work_q_id
		INNER JOIN t_location loc WITH (NOLOCK)
			ON loc.wh_id = wqa.wh_id
			AND loc.c1 = wqa.user_assigned
		INNER JOIN t_stored_item sto WITH (NOLOCK)
			ON sto.wh_id = q.wh_id
			AND sto.item_number = q.item_number
			AND sto.location_id = loc.location_id
		WHERE q.work_status = 'A'
		GROUP BY
			sto.wh_id,
			sto.item_number,
			q.location_id
	) t
	ON r.wh_id = t.wh_id
	AND r.item_number = t.item_number
	AND r.location_id = t.location_id

	--STS 20190702 - Get inventory currently in RP LPNs (staged for replen)
	UPDATE r
	SET actual_qty = actual_qty + rp_qty,
		needs_replen = CASE WHEN actual_qty + rp_qty < max_qty THEN 1 ELSE 0 END
	--OUTPUT DELETED.actual_qty as before_qty, INSERTED.actual_qty as after_qty, DELETED.needs_replen as before_nr, INSERTED.needs_replen as after_nr, INSERTED.location_id, INSERTED.item_number
	FROM #replens r
	INNER JOIN
	(
		SELECT 
			sto.wh_id,
			sto.item_number,
			q.location_id,
			SUM(sto.actual_qty) as rp_qty
		FROM t_hu_master hum WITH (NOLOCK)
		INNER JOIN t_stored_item sto WITH (NOLOCK)
			ON sto.wh_id = hum.wh_id
			AND sto.location_id = hum.location_id
		INNER JOIN t_work_q q WITH (NOLOCK)
			ON hum.hu_id = q.pick_ref_number
			AND sto.item_number = q.item_number
			AND hum.wh_id = q.wh_id
		WHERE hum.type = 'RP'
		AND q.work_status IN ('A','U')
		AND q.work_type = '23'
		GROUP BY
			sto.wh_id,
			sto.item_number,
			q.location_id
	) t2
	ON r.wh_id = t2.wh_id
	AND r.item_number = t2.item_number
	AND r.location_id = t2.location_id


	--Get highest UOM
	UPDATE r
	SET replen_uom = t.uom,
		replen_conversion_factor = t.conversion_factor
	FROM #replens r
	INNER JOIN
	(	SELECT ROW_NUMBER() OVER (PARTITION BY r2.item_number, r2.wh_id ORDER BY conversion_factor DESC) as row_num,
			r2.item_number, r2.wh_id, iu.uom, iu.conversion_factor
		FROM #replens r2
		INNER JOIN t_item_uom iu
			ON r2.item_number = iu.item_number
			AND r2.wh_id = iu.wh_id
		WHERE iu.status = 'ACTIVE'--ISNULL(iu.non_sellable_flag, 0) = 0 --KNC 12/13/17 Updated logic to set repeln uom to be highest uom regardless of if its sellable or not just needs to be an active UOM
		AND ISNULL(iu.ignore_for_replen_flag,0) <> 1 --AMO 2018.2.11 - Added to ignore certain uoms for replen logic.  Addressed an issue with not wanting to replen cig cases
	 ) t
		ON t.item_number = r.item_number
		AND t.wh_id = r.wh_id
	WHERE row_num = 1
		
	IF @in_debug = 1
	BEGIN
		SELECT '#replens', * FROM #replens
		WHERE item_number = '0301895'
	END
	
	

	--Get available overstock inventory
	INSERT INTO #overstock
	SELECT
		sto.wh_id,
		sto.location_id,
		sto.item_number,
		sto.variant_code,
		SUM(sto.actual_qty),
		MIN(sto.fifo_date),
		MIN(sto.expiration_date),
		loc.aisle,
		loc.replen_area
	FROM t_stored_item sto WITH (NOLOCK)
	INNER JOIN
	(	SELECT
			item_number,
			wh_id
		FROM #replens
		WHERE needs_replen = 1
		GROUP BY item_number, wh_id
	 ) r
		ON sto.item_number = r.item_number
		AND sto.wh_id = r.wh_id
	INNER JOIN t_location loc WITH (NOLOCK)
		ON loc.location_id = sto.location_id
		AND loc.wh_id = sto.wh_id
	WHERE loc.type IN ('I','M')
	AND loc.status NOT IN ('I')
	AND sto.status = 'A'
	AND sto.type = 0
	GROUP BY
		sto.wh_id,
		sto.location_id,
		sto.item_number,
		sto.variant_code,
		loc.aisle,
		loc.replen_area

	IF @in_debug = 1
	BEGIN
		SELECT 'overstock',* FROM #overstock
		WHERE item_number = '0301895'
	END

	/*
		Following logic encompasses steps 2,3,4
		2) Regular Slotted Pick bins where demand released for picks in HJ or NAV exceeds current quantity in the location.
			* This will be controlled by a warehouse flag and on by default.
		3) Regular Slotted Pick bins where demand isn’t released for picks in HJ or NAV exceeds current quantity in the location.
			* This will be controlled by a warehouse flag and on by default.
		4) Dynamic Slotted Pick bins where the total demand released for picks exceeds the max of the regular pick bin(s) for the item by more than the max of the dynamic (i.e. we have enough demand to drain the dynamic).  The dynamic slot assignment will be removed if total demand is less than or equal to the quantity in pick bin(s) both dynamic and regular.
	*/

	--Get order demand in Highjump
	INSERT INTO #order_demand
	SELECT
		od.wh_id,
		od.order_number,
		od.line_number,
		od.item_number,
		od.qty,
		od.order_uom,
		od.variant_code,
		1, --mixed_allowed, update later
		NULL, --fpk_uom, update later
		CASE WHEN o.status <> 'RELEASED' THEN 'UNRELEASED' ELSE o.status END,
		0 --processed
	FROM t_order_detail od WITH (NOLOCK)
	INNER JOIN t_order o WITH (NOLOCK)
		ON od.order_number = o.order_number
		AND od.wh_id = o.wh_id
	INNER JOIN t_load_master lm WITH (NOLOCK)
		ON o.load_id = lm.load_id
		AND o.wh_id = lm.wh_id
	WHERE o.status IN ('NEW', 'PROCESSING', 'PROCESSED', 'BUILDING', 'READY', 'RELEASED' )
	AND ISNULL(lm.invoiced_flag, 0) = 0
	AND 1 = CASE WHEN ISNULL(o.order_type, '') = 'TRANSFER' AND ISNULL(o.linked_po, '') <> '' THEN 0 ELSE 1 END --Transfer order with linked PO not picked
	AND 1 = CASE WHEN ISNULL(o.order_type, '') = 'TRANSFER' AND od.order_uom = 'CS' THEN 0 ELSE 1 END --Transfer order for case picked from reserve

	--STS 20180221 - Only get info from NAV where order demand is not in HJ,
	--Updating qty as previously would double order demand erroneously
	--Get order demand in NAV, not already in HJ
	INSERT INTO #order_demand
	SELECT
		na.wh_id,
		na.order_number,
		na.line_number,
		na.item_number,
		na.qty,
		na.uom,
		na.variant_code,
		1, --mixed_allowed, update later
		NULL, --fpk_uom, update later
		'UNRELEASED',
		0 --processed
	FROM t_nav_alloc_order_detail na WITH (NOLOCK)
	LEFT OUTER JOIN #order_demand od
		ON od.wh_id = na.wh_id
		AND od.order_number = na.order_number
		AND od.line_number = na.line_number
		AND od.item_number = na.item_number
	WHERE od.wh_id IS NULL
	
	--Get atomic qty for orders
	UPDATE od
	SET qty = qty * conversion_factor
	FROM #order_demand od
	INNER JOIN t_item_uom iu WITH (NOLOCK)
		ON od.uom = iu.uom
		AND od.item_number = iu.item_number
		AND od.wh_id = iu.wh_id

	IF @in_debug = 1
	BEGIN
		SELECT '#order_demand', * FROM #order_demand
		WHERE item_number = '0301895'
	END

	--Remove quantity that has already been picked
	UPDATE od
	SET qty = qty - picked_qty
	FROM #order_demand od
	INNER JOIN
	(
		SELECT
			pkd.wh_id,
			pkd.order_number,
			pkd.line_number,
			pkd.item_number,
			SUM(pkd.picked_quantity) as picked_qty
		FROM #order_demand od2
		INNER JOIN t_pick_detail pkd WITH (NOLOCK)
			ON od2.wh_id = pkd.wh_id
			AND od2.order_number = pkd.order_number
			AND od2.line_number = pkd.line_number
			AND od2.item_number = pkd.item_number
		WHERE od2.status = 'RELEASED'
		AND pkd.status IN ('PICKED', 'SHORTED', 'LOADED')
		GROUP BY
			pkd.wh_id,
			pkd.order_number,
			pkd.line_number,
			pkd.item_number
	) t
		ON od.wh_id = t.wh_id
		AND od.order_number = t.order_number
		AND od.line_number = t.line_number
		AND od.item_number = t.item_number

	IF @in_debug = 1
	BEGIN
		SELECT '#order_demand after subtracting picks', * FROM #order_demand
		WHERE item_number = '0301895'
	END

	DELETE FROM #order_demand
	WHERE qty <= 0

	--STS 20180920 - Get whether variant can be mixed in inventory (for WA cigs)
	--IF mix is allowed we're treating as an item with no variant, this is so cigs other than for WA
	--orders can be treated together as a single replenishment (since they are post picking stamped)
	UPDATE od
	SET mixed_allowed = ISNULL(j.mixed_allowed, 1),
		variant_code = CASE ISNULL(j.mixed_allowed, 1) WHEN 0 THEN od.variant_code END
	FROM #order_demand od 
	INNER JOIN t_jurisdiction j WITH (NOLOCK)
		ON od.wh_id = j.wh_id
		AND od.variant_code = j.variant_code

	--STS 20180315 - Get the forward pick order demand, the purpose of this is so if there are orders with different
	--UOMs but the same forward pick location, then treat it as a single UOM demand
	UPDATE #order_demand
	SET fpk_uom = ( SELECT TOP 1 fpk.uom
					FROM t_fwd_pick fpk WITH (NOLOCK)
					INNER JOIN t_item_uom iu WITH (NOLOCK)
						ON fpk.item_number = iu.item_number
						AND fpk.uom = iu.uom
						AND fpk.wh_id = iu.wh_id
					WHERE fpk.item_number = #order_demand.item_number
					AND fpk.wh_id = #order_demand.wh_id
					AND ISNULL(fpk.variant_code, '') = ISNULL(#order_demand.variant_code, '')
					ORDER BY
						CASE WHEN fpk.uom = #order_demand.uom THEN 0 ELSE 1 END,
						iu.conversion_factor )
	
	--STS 20180315 - If no fpk_uom, there are no forward pick locs for this item and cannot replen
	DELETE FROM #order_demand WHERE fpk_uom IS NULL

	IF @in_debug = 1
	BEGIN
		SELECT '#order_demand after getting fpk uom', * FROM #order_demand
		WHERE item_number = '0301895'
	END

	--Get control values for whether to do top off
	DECLARE @topoff TABLE
	(
		wh_id NVARCHAR(10),
		topoff_flag INT
	)

	INSERT INTO @topoff (wh_id)
	SELECT wh_id
	FROM t_whse WITH (NOLOCK)

	SET @wh_cnt = @@ROWCOUNT

	UPDATE t
	SET topoff_flag = f1
	FROM @topoff t
	INNER JOIN t_whse_control whc WITH (NOLOCK)
		ON t.wh_id = whc.wh_id
		AND whc.control_type = 'TOPOFF_FLAG'

	--Missing control values for warehouse(s)
	IF @@ROWCOUNT <> @wh_cnt
	BEGIN
		INSERT INTO t_whse_control
		(	wh_id,
			control_type,
			description,
			allow_edit,
			f1
		)
		SELECT
			wh_id,
			'TOPOFF_FLAG',
			'Create top off replens',
			'Y',
			1
		FROM @topoff
		WHERE topoff_flag IS NULL

		UPDATE @topoff SET topoff_flag = 1 WHERE topoff_flag IS NULL
	END

	SET @wh_cnt = 0 --reset value for later use

	--Get control values for whether to base replen on min or demand qty 
	--KNC 2/18/18 adding whse control to have replens be off demand not if below min
	DECLARE @min_demand TABLE
	(
		wh_id NVARCHAR(10),
		prioritize_min_flag INT
	)

	INSERT INTO @min_demand (wh_id)
	SELECT wh_id
	FROM t_whse WITH (NOLOCK)

	SET @wh_cnt = @@ROWCOUNT

	UPDATE t
	SET prioritize_min_flag = f1
	FROM @min_demand t
	INNER JOIN t_whse_control whc WITH (NOLOCK)
		ON t.wh_id = whc.wh_id
		AND whc.control_type = 'RPL_OVER_MIN_DEMAND'

	--Missing control values for warehouse(s)
	IF @@ROWCOUNT <> @wh_cnt
	BEGIN
		INSERT INTO t_whse_control
		(	wh_id,
			control_type,
			description,
			allow_edit,
			f1
		)
		SELECT
			wh_id,
			'RPL_OVER_MIN_DEMAND',
			'Rpl prioritize demand over min',
			'Y',
			CASE wh_id WHEN 'LDC' THEN 0 ELSE 1 END
		FROM @min_demand
		WHERE prioritize_min_flag IS NULL

		UPDATE @min_demand SET prioritize_min_flag = CASE wh_id WHEN 'LDC' THEN 0 ELSE 1 END WHERE prioritize_min_flag IS NULL

	END

	SET @wh_cnt = 0 --reset value for later use with topoff's
	
	--Loop through order demand
	WHILE EXISTS (SELECT 1 FROM #order_demand WHERE processed = 0)
	BEGIN
		--Get next demand item
		SELECT TOP 1
			@r_wh = wh_id,
			@r_item = item_number,
			--@o_uom = uom,
			@demand_qty = SUM(qty),
			@released_qty = SUM(CASE status WHEN 'RELEASED' THEN qty ELSE 0 END),
			@unreleased_qty = SUM(CASE status WHEN 'UNRELEASED' THEN qty ELSE 0 END),
			@avail_qty = 0,
			@order_status = '',
			@fpk_uom = fpk_uom,
			@variant_code = variant_code
		FROM #order_demand
		WHERE processed = 0
		GROUP BY
			wh_id,
			item_number,
			fpk_uom,
			variant_code

		--Get the UOM for the forward pick location, there may not be a 
		--forward pick that matches the order uom (each case scenario)
		--SELECT TOP 1
		--	@fpk_uom = uom
		--FROM t_fwd_pick WITH (NOLOCK)
		--WHERE item_number = @r_item
		--AND wh_id = @r_wh
		--ORDER BY
		--	CASE WHEN uom = @o_uom THEN 0 ELSE 1 END
			
		--Get total quantity available for this item/uom in pick faces
		SELECT @avail_qty = SUM(actual_qty)
		FROM #replens
		WHERE wh_id = @r_wh
		AND item_number = @r_item
		AND fpk_uom = @fpk_uom
		AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')

		IF @in_debug = 1 and @r_item = '0301895'
		BEGIN
			SELECT @r_wh as wh, @r_item as demand_item, @fpk_uom as fpk_uom, @demand_qty as demand_qty,
				@released_qty as released_qty, @unreleased_qty as unreleased_qty, @avail_qty as avail_qty
		END

		--Check if available quantity meets the needed quantity
		IF ISNULL(@avail_qty, 0) < @demand_qty
		BEGIN
			--Get the order with most relevant status
			SELECT TOP 1
				@order_status = status,
				@order_number = order_number,
				@line_number = line_number
			FROM #order_demand
			WHERE processed = 0
			AND wh_id = @r_wh
			AND item_number = @r_item
			--AND uom = @o_uom
			AND fpk_uom = @fpk_uom
			AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')
			ORDER BY ISNULL(NULLIF(CHARINDEX(status,'RELEASED,UNRELEASED,IN_NAV'),0),99999)

			IF @in_debug = 1 and @r_item = '0301895'
			BEGIN
				SELECT @order_status as order_status, @order_number as order_number, @line_number as line_number, @r_wh as r_wh, @variant_code as variant_code,
				ISNULL(@avail_qty, 0) as avail_qty, ISNULL(@demand_qty, 0) as demand_qty
			END

			--Check if assigned with not enough inventory avail
			IF @order_status = 'RELEASED'
			BEGIN
				--STS 20171212
				--If there is an outchaser that cannot be fulfilled with inventory available then
				--we will set the replenishment to an even higher priority (95)
				SELECT
					@outchaser_released_qty = SUM(CASE pkd.status WHEN 'RELEASED' THEN planned_quantity - picked_quantity ELSE 0 END),
					@outchaser_unreleased_qty = SUM(CASE pkd.status WHEN 'NEW' THEN planned_quantity - picked_quantity ELSE 0 END)
				FROM #order_demand od
				INNER JOIN t_pick_detail pkd WITH (NOLOCK)
					ON od.order_number = pkd.order_number
					AND od.line_number = pkd.line_number
					AND od.wh_id = pkd.wh_id
				WHERE od.processed = 0
				AND od.wh_id = @r_wh
				AND od.item_number = @r_item
				--AND od.uom = @o_uom
				AND od.fpk_uom = @fpk_uom
				AND ISNULL(od.variant_code, '') = ISNULL(@variant_code, '')
				AND od.status = 'RELEASED'
				AND pkd.work_type = '05'
				AND pkd.status IN ('NEW', 'RELEASED')

				IF @in_debug = 1 and @r_item = '0301895'
				BEGIN
					SELECT @outchaser_released_qty as outchaser_released_qty, @outchaser_unreleased_qty as outchaser_unreleased_qty

					SELECT 'assigned',pkm.pick_master_id, od.wh_id, od.item_number, od.uom, SUM(pkd.planned_quantity) as planned_qty
					FROM #order_demand od
					INNER JOIN t_pick_detail pkd WITH (NOLOCK)
						ON od.order_number = pkd.order_number
						AND od.line_number = pkd.line_number
						AND od.wh_id = pkd.wh_id
					INNER JOIN t_pick_master pkm WITH (NOLOCK)
						ON pkd.pick_master_id = pkm.pick_master_id
					WHERE od.processed = 0 
					AND od.wh_id = @r_wh
					AND od.item_number = @r_item
					--AND od.uom = @o_uom
					AND od.fpk_uom = @fpk_uom
					AND ISNULL(od.variant_code, '') = ISNULL(@variant_code, '')
					AND od.status = 'RELEASED'
					AND pkd.status = 'RELEASED'
					AND ISNULL(pkm.user_assign, '') <> ''
					GROUP BY pkm.pick_master_id, od.wh_id, od.item_number, od.uom
					HAVING SUM(pkd.planned_quantity) > ISNULL(@avail_qty, 0)
				END

				IF ISNULL(@avail_qty, 0) < ISNULL(@outchaser_released_qty, 0) AND ISNULL(@outchaser_released_qty, 0) > 0
				BEGIN
					SET @order_status = 'OUTCHASER_R'
				END
				ELSE IF EXISTS
				(	SELECT 1
					FROM #order_demand od
					INNER JOIN t_pick_detail pkd WITH (NOLOCK)
						ON od.order_number = pkd.order_number
						AND od.line_number = pkd.line_number
						AND od.wh_id = pkd.wh_id
						AND ISNULL(od.variant_code, ISNULL(pkd.variant_code, '')) = ISNULL(pkd.variant_code, '')
					INNER JOIN t_pick_master pkm WITH (NOLOCK)
						ON pkd.pick_master_id = pkm.pick_master_id
					WHERE od.processed = 0 
					AND od.wh_id = @r_wh
					AND od.item_number = @r_item
					--AND od.uom = @o_uom
					AND od.fpk_uom = @fpk_uom
					AND ISNULL(od.variant_code, '') = ISNULL(@variant_code, '')
					AND od.status = 'RELEASED'
					AND pkd.status = 'RELEASED'
					AND ISNULL(pkm.user_assign, '') <> ''
					GROUP BY pkm.pick_master_id, od.wh_id, od.item_number, od.uom
					HAVING SUM(pkd.planned_quantity) > ISNULL(@avail_qty, 0) )
				BEGIN
					SET @order_status = 'ASSIGNED'
				END
				ELSE IF ISNULL(@avail_qty, 0) < ISNULL(@outchaser_unreleased_qty, 0) AND ISNULL(@outchaser_unreleased_qty, 0) > 0
				BEGIN
					SET @order_status = 'OUTCHASER_U'
				END
			END

			--STS 20180308 - Determine what priority based off of released/unreleased qty and demand
			IF @order_status NOT IN ('OUTCHASER_R', 'OUTCHASER_U', 'ASSIGNED')
			BEGIN
				IF ISNULL(@avail_qty, 0) < @released_qty
				BEGIN
					SET @order_status = 'RELEASED'
				END
				--If released demand does not exceed avail quantity, consider as unreleased
				ELSE
				BEGIN
					SET @order_status = 'UNRELEASED'
				END
			END

			--Set demand to total demand minus what is available
			SET @demand_qty = @demand_qty - ISNULL(@avail_qty, 0)

			IF @in_debug = 1 and @r_item = '0301895'
			BEGIN
				SELECT @order_status as order_status, @order_number as order_number, @line_number as line_number, @r_wh as r_wh, @variant_code as variant_code,
				ISNULL(@avail_qty, 0) as avail_qty, ISNULL(@demand_qty, 0) as final_demand_qty
			END

			--Loop until demand is met 
			WHILE @demand_qty > 0
			BEGIN				

				SELECT TOP 1
					@r_id = r.r_id,
					@r_loc = r.location_id,
					@r_aisle = r.preferred_overstock_aisle,
					@needed_qty = r.max_qty - r.actual_qty,
					@replen_area = r.replen_area,
					@is_dynamic = ISNULL(r.is_dynamic, 0),
					@r_uom = r.replen_uom,
					@r_conv = ISNULL(r.replen_conversion_factor, 1),
					@fpk_conv = ISNULL(r.fpk_conversion_factor, 1),
					@below_min = CASE WHEN ISNULL(r.actual_qty, 0) <= min_qty THEN 1 ELSE 0 END,
					@single_replen_flag = r.single_replen_flag,
					@single_replen_unique_id = r.single_replen_unique_id
				FROM #replens r
				INNER JOIN @topoff t
					ON r.wh_id = t.wh_id
				WHERE r.wh_id = @r_wh
				AND r.item_number = @r_item
				AND r.fpk_uom = @fpk_uom
				AND ISNULL(r.variant_code, '') = ISNULL(@variant_code, '')
				AND r.needs_replen = 1
				AND (ISNULL(r.actual_qty, 0) <= min_qty OR ISNULL(topoff_flag, 1) = 1)
				--Consider non-dynamic first for replenishment
				ORDER BY CASE WHEN ISNULL(is_dynamic, 0) = 0 THEN 0 ELSE 1 END

				SET @more_to_process = @@ROWCOUNT

				IF @in_debug = 1 and @r_item = '0301895'
				BEGIN
					SELECT @more_to_process as more_to_process, @needed_qty as needed_qty, @is_dynamic as is_dynamic,
					@r_loc as r_loc, @r_aisle as r_aisle, @r_uom as r_uom, @r_conv as r_conv, @fpk_conv as fpk_conv
				END

				IF @more_to_process > 0
				BEGIN
					--If dynamic, we will not fill pick face to max unless we need that much
					IF @is_dynamic = 1 AND @needed_qty > @demand_qty AND ISNULL(@single_replen_flag, 0) = 0
					BEGIN
						SET @needed_qty = @demand_qty
					END

					WHILE @needed_qty > 0
					BEGIN
						IF @in_debug = 1 and @r_item = '0301895'
						BEGIN
							SELECT 'before finding overstock', @r_wh as r_wh, @r_item as r_item, @r_conv
							SELECT 'before finding overstock',* FROM #overstock WHERE item_number = @r_item
							ORDER BY
								ISNULL(expiration_date, fifo_date),
								fifo_date,
								CASE WHEN ISNULL(aisle, '') = ISNULL(@r_aisle, '') THEN 0 ELSE 1 END,
								actual_qty
						END

						SELECT TOP 1
							@o_id = o_id,
							@o_wh = wh_id,
							@o_loc = location_id,
							@o_item = item_number,
							@o_qty = actual_qty,
							@o_replen_area = replen_area
						FROM #overstock
						WHERE wh_id = @r_wh
						AND item_number = @r_item
						AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')
						AND actual_qty >= @r_conv --At least enough quantity to fulfill the conversion factor for replen
						ORDER BY
							ISNULL(expiration_date, fifo_date),
							fifo_date,
							CASE WHEN ISNULL(aisle, '') = ISNULL(@r_aisle, '') THEN 0 ELSE 1 END,
							actual_qty

						IF @@ROWCOUNT = 0
						BEGIN	
							IF @in_debug = 1 and @r_item = '0301895'
							BEGIN
								SELECT 'no overstock qty found', @r_item as item_number
							END

							SELECT @opk_qty = 0, @opk_loc = NULL, @opk_uom = NULL, @opk_demand_qty = 0															
							--Check if there is a forward pick location in another area that
							--can be replened from depending on order demand
							SELECT TOP 1
								@opk_qty = SUM(actual_qty),
								@opk_loc = location_id,
								@opk_uom = fpk_uom,
								@opk_replen_area = replen_area
							FROM #replens
							WHERE location_id <> @r_loc
							--Must come from pick loc with UOM equal or greater
							--No replen from each to case for instance
							AND fpk_conversion_factor >= @fpk_conv 
							AND item_number = @r_item
							AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')
							AND wh_id = @r_wh							
							GROUP BY location_id, wh_id, fpk_uom, replen_area

							--If other forward pick quantity available
							IF ISNULL(@opk_qty, 0) > 0
							BEGIN
								--Get the demand for other forward pick uom
								SELECT @opk_demand_qty = SUM(qty)
								FROM #order_demand
								WHERE processed = 0 
								AND wh_id = @r_wh
								AND item_number = @r_item
								AND uom = @opk_uom
								AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')

								--Calculate replen qty, if more in location than for demand can do
								--a replen from pick face to pick face
								SET @replen_qty = ISNULL(@opk_qty, 0) - ISNULL(@opk_demand_qty, 0)

								--Only move as much as is needed to fulfill demand for pick face to
								--pick face
								IF @replen_qty > @demand_qty
								BEGIN
									SET @replen_qty = @demand_qty
								END

								IF ISNULL(@replen_qty, 0) > 0
								BEGIN
									--Convert quantity to uom quantity that we are working with
									SET @replen_qty = @replen_qty / @r_conv

									--Create record for replen to create
									INSERT INTO #replens_to_create
									SELECT
										@r_wh,
										@r_loc,
										@opk_loc,
										@r_item,
										@replen_qty,
										'22',
										CASE @below_min WHEN 1 THEN '01' ELSE '02' END,
										@opk_replen_area,
										CASE @order_status
											WHEN 'OUTCHASER_R' THEN '95'
											WHEN 'ASSIGNED' THEN '90'
											WHEN 'OUTCHASER_U' THEN '85'
											WHEN 'RELEASED' THEN CASE @below_min WHEN 1 THEN '80' ELSE CASE md.prioritize_min_flag WHEN 1 THEN '80' ELSE '70' END END
											WHEN 'UNRELEASED' THEN CASE @below_min WHEN 1 THEN '75' ELSE CASE md.prioritize_min_flag WHEN 1 THEN '75' ELSE '65' END END
											--WHEN 'IN_NAV' THEN '60'
											ELSE '60'
										END as priority,
										@r_uom as uom,
										@single_replen_unique_id as pick_ref_number
									FROM @min_demand md
									WHERE md.wh_id = @r_wh
								END
							END

							SET @needed_qty = 0	

						END
						--Set to quantity to lesser of available quantity and needed quantity
						ELSE
						BEGIN
							IF @in_debug = 1 and @r_item = '0301895'
							BEGIN
								SELECT
								@o_id as o_id,
								@o_wh as o_wh,
								@o_loc as o_loc,
								@o_item as o_item,
								@o_qty as o_qty,
								@o_replen_area as o_replen_area
							END

							IF @o_qty > @needed_qty
								SET @o_qty = @needed_qty
							
							--Convert quantity to uom quantity that we are working with
							SET @replen_qty = @o_qty / @r_conv
							
							--Create record for replen to create
							INSERT INTO #replens_to_create
							SELECT
								@o_wh,
								@r_loc,
								@o_loc,
								@o_item,
								@replen_qty,
								'22',
								CASE @below_min WHEN 1 THEN '01' ELSE '02' END,
								@o_replen_area,
								CASE @order_status
									WHEN 'OUTCHASER_R' THEN '95'
									WHEN 'ASSIGNED' THEN '90'
									WHEN 'OUTCHASER_U' THEN '85'
									WHEN 'RELEASED' THEN CASE @below_min WHEN 1 THEN '80' ELSE CASE md.prioritize_min_flag WHEN 1 THEN '80' ELSE '70' END END
									WHEN 'UNRELEASED' THEN CASE @below_min WHEN 1 THEN '75' ELSE CASE md.prioritize_min_flag WHEN 1 THEN '75' ELSE '65' END END
									--WHEN 'IN_NAV' THEN '60'
									ELSE '60'
								END as priority,
								@r_uom as uom,
								@single_replen_unique_id as pick_ref_number
							FROM @min_demand md
							WHERE md.wh_id = @o_wh

							--Update temp table with inventory we have taken away
							UPDATE #overstock
							SET actual_qty = actual_qty - @o_qty
							WHERE o_id = @o_id

							SET @needed_qty = @needed_qty - @o_qty
							SET @demand_qty = @demand_qty - @o_qty

							IF @in_debug = 1 and @r_item = '0301895'
							BEGIN
								SELECT 'order demand end', @needed_qty as needed_qty, @demand_qty as demand_qty, @o_qty as o_qty
							END
						END
					END

					--Remove this record from replens as we have fulfilled it as much as possible at this point
					DELETE FROM #replens WHERE r_id = @r_id
				END
				--Couldn't find anymore pick faces with room
				ELSE
				BEGIN
					SET @demand_qty = 0
				END
			END --End looping through demand qty
		END --End finding qty for demand

		-- Delete from temp table as have processed the item
		UPDATE #order_demand
		SET processed = 1
		WHERE wh_id = @r_wh
		AND item_number = @r_item
		--AND uom = @o_uom
		AND fpk_uom = @fpk_uom
		AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')
	END

	IF @in_debug = 1
	BEGIN
		SELECT 'After order demand'
		SELECT '#replens_to_create', * FROM #replens_to_create
		WHERE item_number = '0301895'

		SELECT '#overstock', * FROM #overstock
		WHERE item_number = '0301895'
	END

	/*
		1) Regular Slotted Pick bins with current inventory at or below the minimum qty set
	*/

	SET @more_to_process = 1
	SET @r_id = 0

	--1) Regular Slotted Pick bins with current inventory at or below the minimum qty set
	WHILE (@more_to_process > 0)
	BEGIN
		SELECT TOP 1
			@r_wh = wh_id,
			@r_id = r_id,
			@r_loc = location_id,
			@r_item = item_number,
			@r_aisle = preferred_overstock_aisle,
			@needed_qty = max_qty - actual_qty,
			@replen_area = replen_area,
			@r_uom = replen_uom,
			@r_conv = replen_conversion_factor,
			@variant_code = variant_code,
			@single_replen_unique_id = single_replen_unique_id
		FROM #replens
		WHERE actual_qty <= min_qty
		AND r_id > @r_id
		AND needs_replen = 1
		AND ISNULL(is_dynamic, 0) = 0
		ORDER BY r_id

		SET @more_to_process = @@ROWCOUNT

		IF @more_to_process > 0
		BEGIN
			WHILE @needed_qty > 0
			BEGIN
				IF @in_debug = 1 AND @r_item = '0301895'
				BEGIN
					SELECT 'minmax', @r_wh as r_wh, @r_item as r_item, @variant_code as variant_code, @r_loc as r_loc, @needed_qty as needed_qty
					SELECT 'Avail overstock',*
					FROM #overstock
					WHERE wh_id = @r_wh
					AND item_number = @r_item
					AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')
					AND actual_qty > 0
					AND actual_qty >= @r_conv --6.0 
				END

				SELECT TOP 1
					@o_id = o_id,
					@o_wh = wh_id,
					@o_loc = location_id,
					@o_item = item_number,
					@o_qty = actual_qty,
					@o_replen_area = replen_area
				FROM #overstock
				WHERE wh_id = @r_wh
				AND item_number = @r_item
				AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')
				AND actual_qty >= @r_conv --At least enough quantity to fulfill the conversion factor for replen 6.0, changed from = to >=
				ORDER BY
					ISNULL(expiration_date, fifo_date),
					fifo_date,
					CASE WHEN ISNULL(aisle, '') = ISNULL(@r_aisle, '') THEN 0 ELSE 1 END,
					actual_qty

				IF @@ROWCOUNT = 0
				BEGIN
					SET @needed_qty = 0
				END
				--Set to quantity to lesser of available quantity and needed quantity
				ELSE
				BEGIN
					IF @o_qty > @needed_qty
						SET @o_qty = @needed_qty
						
					--Convert quantity to uom quantity that we are working with
					SET @replen_qty = @o_qty / @r_conv

					IF @replen_qty = 0
					BEGIN
						SET @needed_qty = 0
						CONTINUE
					END

					--Create record for replen to create
					INSERT INTO #replens_to_create
					SELECT
						@o_wh,
						@r_loc,
						@o_loc,
						@o_item,
						@replen_qty,
						'22',
						'01',
						@o_replen_area,
						CASE WHEN EXISTS
						(	SELECT 1 
							FROM #order_demand
							WHERE item_number = @o_item
							AND wh_id = @o_wh
							AND uom = @r_uom
							AND qty > 0
						) THEN '60' ELSE '55' END,
						@r_uom as uom,
						@single_replen_unique_id as pick_ref_number

					--Update temp table with inventory we have taken away
					UPDATE #overstock
					SET actual_qty = actual_qty - @o_qty
					WHERE o_id = @o_id

					SET @needed_qty = @needed_qty - (@replen_qty * @r_conv)
				END
			END

			--Remove this record from replens as we have fulfilled it as much as possible at this point
			DELETE FROM #replens WHERE r_id = @r_id
		END
	END

	IF @in_debug = 1
	BEGIN
		SELECT 'After min/max'
		SELECT '#replens_to_create', * FROM #replens_to_create
		WHERE item_number = '0301895'
		SELECT '#overstock', * FROM #overstock
		WHERE item_number = '0301895'
	END

	/*
		5) Top Off replenishments where pick bin location is below the max threshold.
				* This will be controlled by a warehouse flag and on by default.
	*/
	
	SET @more_to_process = 1
	SET @r_id = 0

	--Any remaining replens in the table at this point will be top offs as we have already
	--considered min/max and order demand
	WHILE (@more_to_process > 0)
	BEGIN
		SELECT TOP 1
			@r_wh = r.wh_id,
			@r_id = r_id,
			@r_loc = location_id,
			@r_item = item_number,
			@r_aisle = preferred_overstock_aisle,
			@needed_qty = max_qty - actual_qty,
			@replen_area = replen_area,
			@r_uom = replen_uom,
			@r_conv = replen_conversion_factor,
			@variant_code = variant_code
		FROM #replens r
		INNER JOIN @topoff t
			ON r.wh_id = t.wh_id
		WHERE r_id > @r_id
		AND ISNULL(is_dynamic, 0) = 0
		AND ISNULL(topoff_flag, 1) = 1 --Warehouse must be set for top off
		AND needs_replen = 1
		ORDER BY r_id

		SET @more_to_process = @@ROWCOUNT

		IF @more_to_process > 0
		BEGIN
			WHILE @needed_qty > 0
			BEGIN

				SELECT TOP 1
					@o_id = o_id,
					@o_wh = wh_id,
					@o_loc = location_id,
					@o_item = item_number,
					@o_qty = actual_qty,
					@o_replen_area = replen_area
				FROM #overstock
				WHERE wh_id = @r_wh
				AND item_number = @r_item
				AND ISNULL(variant_code, '') = ISNULL(@variant_code, '')
				AND actual_qty > @r_conv --At least enough quantity to fulfill the conversion factor for replen
				ORDER BY
					ISNULL(expiration_date, fifo_date),
					fifo_date,
					CASE WHEN ISNULL(aisle, '') = ISNULL(@r_aisle, '') THEN 0 ELSE 1 END,
					actual_qty

				IF @@ROWCOUNT = 0
				BEGIN
					SET @needed_qty = 0
				END
				--Set to quantity to lesser of available quantity and needed quantity
				ELSE
				BEGIN
					IF @o_qty > @needed_qty
						SET @o_qty = @needed_qty
						
					--Convert quantity to uom quantity that we are working with
					SET @replen_qty = @o_qty / @r_conv

					IF @replen_qty = 0
					BEGIN
						SET @needed_qty = 0
						CONTINUE
					END

					--Create record for replen to create
					INSERT INTO #replens_to_create
					SELECT
						@o_wh,
						@r_loc,
						@o_loc,
						@o_item,
						@replen_qty,
						'22',
						'02', --top off sub type
						@o_replen_area,
						'40',
						@r_uom as uom,
						NULL as pick_ref_number

					--Update temp table with inventory we have taken away
					UPDATE #overstock
					SET actual_qty = actual_qty - @o_qty
					WHERE o_id = @o_id

					SET @needed_qty = @needed_qty - (@replen_qty * @r_conv)
				END
			END

			--Remove this record from replens as we have fulfilled it as much as possible at this point
			DELETE FROM #replens WHERE r_id = @r_id
		END
	END

	IF @in_debug = 1
	BEGIN
		SELECT 'After top off'
		SELECT '#replens_to_create', * FROM #replens_to_create
		WHERE item_number = '0301895'
		SELECT '#overstock', * FROM #overstock
		WHERE item_number = '0301895'
	END

	--UPDATE rc
	--SET qty = CASE
	--			WHEN sto.actual_qty / uom.conversion_factor < dsr.qty THEN FLOOR(sto.actual_qty / uom.conversion_factor)
	--			ELSE dsr.qty
	--		END
	--FROM #replens_to_create rc
	--INNER JOIN t_dynamic_single_replen_queue dsr WITH(NOLOCK)
	--	ON dsr.status = 'N'
	--	AND dsr.location_id = rc.location_id
	--	AND dsr.item_number = rc.item_number
	--	AND dsr.uom = rc.uom
	--	AND dsr.wh_id = rc.wh_id
	--INNER JOIN t_stored_item sto WITH(NOLOCK)
	--	ON sto.location_id = rc.from_location_id
	--	AND sto.wh_id = rc.wh_id
	--	AND sto.item_number = rc.item_number
	--INNER JOIN t_item_uom uom WITH(NOLOCK)
	--	ON uom.item_number = rc.item_number
	--	AND uom.uom = rc.uom
	--	AND uom.wh_id = rc.wh_id

	UPDATE dsr
	SET
	 replenished_qty = rc.qty
	,status = 'P'
	,processed_date = GETDATE()
	FROM t_dynamic_single_replen_queue dsr
	INNER JOIN
	(
		SELECT
			SUM(rc.qty) as qty,
			rc.pick_ref_number
		FROM #replens_to_create rc
		WHERE rc.pick_ref_number IS NOT NULL
		GROUP BY
			rc.pick_ref_number
	) rc
		ON CONVERT(NVARCHAR(30), dsr.unique_id) = rc.pick_ref_number
	WHERE dsr.status <> 'P'
		
	--Merge t_work_q, create new replens for any work that doesn't exist
	--Update the qty on existing work if not already assigned
	MERGE t_work_q as dst
	USING
	(	SELECT
			rc.wh_id,
			rc.location_id,
			rc.from_location_id,
			rc.item_number,
			MAX(rc.qty) as qty,
			rc.work_type,
			rc.replen_area,
			rc.sub_work_type,
			ISNULL(wt.description, 'Replenishment') as [description],
			MAX(rc.[priority]) as priority,
			rc.uom,
			rc.pick_ref_number
		FROM #replens_to_create rc
		LEFT OUTER JOIN t_work_types wt WITH (NOLOCK)
			ON rc.work_type = wt.work_type
			AND rc.sub_work_type = wt.sub_type
			AND rc.wh_id = wt.wh_id
		WHERE rc.qty > 0
		GROUP BY
			rc.wh_id,
			rc.location_id,
			rc.from_location_id,
			rc.item_number,
			rc.work_type,
			rc.replen_area,
			rc.sub_work_type,
			wt.description,
			rc.uom,
			rc.pick_ref_number
	) as src
	ON src.wh_id = dst.wh_id
	AND src.location_id = dst.location_id
	AND src.from_location_id = dst.from_location_id
	AND src.item_number = dst.item_number
	AND src.work_type = dst.work_type
	AND src.sub_work_type = dst.sub_work_type
	AND dst.work_status IN ('U', 'A')
	WHEN MATCHED AND dst.work_status = 'U' THEN UPDATE
	SET dst.qty = src.qty,
		dst.priority = src.priority,
		dst.uom = src.uom,
		dst.replen_area = src.replen_area,
		dst.pick_ref_number = src.pick_ref_number
	WHEN NOT MATCHED THEN INSERT
	(
		work_type,
		description,
		priority,
		item_number,
		wh_id,
		location_id,
		from_location_id,
		qty,
		replen_area,
		sub_work_type,
		uom,
		pick_ref_number
	)
	VALUES
	(
		src.work_type,
		src.description,
		src.priority,
		src.item_number,
		src.wh_id,
		src.location_id,
		src.from_location_id,
		src.qty,
		src.replen_area,
		src.sub_work_type,
		src.uom,
		src.pick_ref_number
	);

	--Close work that is no longer needed
	/*
	UPDATE q
	SET work_status = 'C'
	FROM t_work_q q
	LEFT OUTER JOIN #replens_to_create rc
		ON q.wh_id = rc.wh_id
		AND q.location_id = rc.location_id
		AND q.from_location_id = rc.from_location_id
		AND q.item_number = rc.item_number
		AND q.work_type = rc.work_type
		AND q.sub_work_type = rc.sub_work_type
	WHERE q.work_status = 'U'
	AND (rc.location_id IS NULL OR ISNULL(rc.qty, 0) = 0)
	AND q.work_type = '22'
	*/

	UPDATE q
	SET work_status = 'C'
	FROM t_work_q q
	WHERE q.work_status = 'U'
	AND q.work_type = '22'
	AND NOT EXISTS
	(	SELECT 1
		FROM #replens_to_create rc 
		WHERE q.wh_id = rc.wh_id
		AND q.location_id = rc.location_id
		AND q.from_location_id = rc.from_location_id
		AND q.item_number = rc.item_number
		AND q.work_type = rc.work_type
		AND q.sub_work_type = rc.sub_work_type
		AND ISNULL(rc.qty, 0) > 0 )
	
	--Delete dynamic forward pick locations where 
	--there is no need for a replenishment
	--and the location is empty
	--Replens to create should always hold all the locations that could
	--possibly need replenishments so using this to determine if the
	--dynamic forward pick is no longer needed
	DELETE fpk
	FROM t_fwd_pick fpk
	LEFT OUTER JOIN #replens r
		ON fpk.location_id = r.location_id
		AND fpk.item_number = r.item_number
		AND fpk.wh_id = r.wh_id
	INNER JOIN t_location loc WITH (NOLOCK)
		ON fpk.location_id = loc.location_id
		AND fpk.wh_id = loc.wh_id
	LEFT OUTER JOIN t_stored_item sto WITH (NOLOCK)
		ON loc.location_id = sto.location_id
		AND loc.wh_id = sto.wh_id
		AND fpk.item_number = sto.item_number
	LEFT OUTER JOIN #replens_to_create rc
		ON loc.location_id = rc.location_id
		AND loc.wh_id = rc.wh_id
		AND fpk.item_number = rc.item_number
	--Make sure no open replen puts destined for this location
	LEFT OUTER JOIN t_work_q q WITH (NOLOCK)
		ON loc.location_id = rc.location_id
		AND loc.wh_id = rc.wh_id
		AND fpk.item_number = rc.item_number
		AND q.work_type = '23'
		AND q.work_status IN ('U', 'A')
	WHERE sto.sto_id IS NULL --empty
	AND rc.location_id IS NULL --No replens to create 
	AND loc.is_dynamic = 1
	AND ISNULL(fpk.auto_remove, 0) = 1
	AND q.location_id IS NULL
	--STS 20190711 - Do not remove forward pick if quantity in transit
	AND ISNULL(r.qty_in_transit, 0) = 0
	--STS 20190711 - Don't consider forward pick for deletion that wasn't processed, could have been added mid-job run.
	--Could not be in #replens if complete single replen so also consider that condition.
	AND (r.location_id IS NOT NULL  
		OR (fpk.single_replen_flag = 1
			AND
			'C' = (	SELECT TOP 1 [status]
					FROM t_dynamic_single_replen_queue q WITH (NOLOCK)
					WHERE fpk.location_id = q.location_id
					AND fpk.wh_id = q.wh_id
					AND fpk.uom = q.uom
					AND fpk.item_number = q.item_number
					ORDER BY q.unique_id DESC )
			)
		)

END TRY
BEGIN CATCH
	
	--On error rollback transaction and bail out
	IF @@TRANCOUNT > 0
		ROLLBACK TRAN
		
	PRINT ERROR_LINE()
	PRINT ERROR_MESSAGE()
	
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
