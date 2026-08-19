USE [AAD]
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


ALTER PROCEDURE [dbo].[usp_ww_inbound_appointment_new]
	@in_ww_username		NVARCHAR(MAX),
	@in_wh_id			VARCHAR(10),
	@in_appt_type    	NVARCHAR (10),
	@in_trailer  		NVARCHAR(50),
	@in_carrier_id	   INT,
	@in_carrier_name    NVARCHAR(100),
	@in_carrier_code    NVARCHAR(30),
	@in_door			NVARCHAR(50),
	@in_po				NVARCHAR(MAX),
	@in_comments		NVARCHAR(MAX),
	@in_arrival         DATETIME,
	@in_departure       DATETIME,
	@in_unload          DATETIME
	--,@in_timeslot_id     INT

AS
BEGIN
SET NOCOUNT ON;


/*********************************************************************************************************************************
Description: Add New Appointment, page 1708 

  Version	Date		Intials		Repo	Notes
  -------	--------	-------		------	-----------------------------------------------
  1.0       20170327    SJD                 Created 
  2.0       20171019    KJD                 Added UPPER to PO Check 
  3.0       20260731    BEW-HWF     HW06    Added error handling for PO's that are already scheduled
  4.0		20260819	BEW-HWF		HW08	Per warehouse, they want to remove 3.0 logic. 
*********************************************************************************************************************************/

	
	DECLARE @priority INT = 50
	,@carrier_id INT
	,@carrier_code NVARCHAR(30)
	,@xml		   XML
	,@appointment  INT
	,@error_po NVARCHAR(50)


BEGIN TRY
	DECLARE
		@error_num INT,
		@error_msg NVARCHAR(MAX)

	SET @in_door = NULLIF(@in_door,'')

	SET @in_po =  REPLACE(REPLACE(UPPER(@in_po), CHAR(13), ''), CHAR(10), '')

	CREATE TABLE #pos
	(
		 wh_id				NVARCHAR(10)
		,po					NVARCHAR(30)
	)

	IF @in_trailer LIKE '%[^a-zA-Z0-9]%' 
		RAISERROR('Invalid Characters In Trailer',18,1)
	
	IF ISNULL(@in_po,'') <> ''
	BEGIN 
	SELECT
		@xml = CONVERT(XML,(CONCAT('<t>',REPLACE(@in_po,',','</t><t>'),'</t>')))

	INSERT INTO #pos (wh_id,po)
	SELECT
		 @in_wh_id						AS [wh_id]
		,LTRIM(RTRIM(t.value('.','NVARCHAR(30)')))	AS po
	FROM @xml.nodes('/t') AS x(t)

	IF EXISTS (SELECT 8 FROM #pos pos LEFT JOIN t_po_master pom WITH (NOLOCK) ON UPPER(pom.po_number) = UPPER(pos.po) AND pom.wh_id = pos.wh_id WHERE ISNULL(pom.wh_id,'') = '') 
		RAISERROR('Invalid POs',18,1)
	END

	SELECT TOP 1 @error_po = pos.po 
	FROM t_po_master po WITH (NOLOCK) 
	INNER JOIN #pos pos 
	    ON pos.po = po.po_number
	    AND po.wh_id = pos.wh_id
	WHERE po.status <> 'O'

	IF @@ROWCOUNT > 0 
	BEGIN
		SET @error_msg = 'PO Not Open ' + @error_po
		RAISERROR(@error_msg,18,1)
		GOTO EXIT_LABEL
	END
--4.0 Begin 
/*
--3.0 Begin 
	IF EXISTS ( SELECT 1
				FROM t_appointment_po ap WITH (NOLOCK)
				INNER JOIN t_appointment ta WITH (NOLOCK) 
					ON ap.appointment_id = ta.appointment_id
					AND ap.wh_id = ta.wh_id 
				INNER JOIN #pos pos 
					ON ap.wh_id = pos.wh_id 
					AND ap.po_number = pos.po 
				WHERE ta.[status] IN ( 'ON PREM', 'SCHEDULED', 'UNLOADED', 'UNLOADING' )
			)
	BEGIN 
        SELECT TOP 1 @error_po = ap.po_number 
        FROM t_appointment_po ap WITH (NOLOCK)
        INNER JOIN t_appointment ta WITH (NOLOCK) 
            ON ap.appointment_id = ta.appointment_id
            AND ap.wh_id = ta.wh_id 
        INNER JOIN #pos pos 
            ON ap.wh_id = pos.wh_id 
            AND ap.po_number = pos.po 
        WHERE ta.[status] IN ( 'ON PREM', 'SCHEDULED', 'UNLOADED', 'UNLOADING' )

		SET @error_msg = @error_po + ' on an open appointment. Cannot schedule on multiple appointments.'
 		RAISERROR(@error_msg,18,1)
		GOTO EXIT_LABEL
	END
--3.0 End 
*/ 
--4.0 End 

	IF @in_carrier_id = -1  AND (ISNULL(@in_carrier_code,'') = '' OR ISNULL(@in_carrier_name,'') = '')
	RAISERROR('Invalid Carrier',18,1)

	IF @in_carrier_id = -1 AND NOT EXISTS (SELECT 8 FROM t_carrier WITH(NOLOCK) WHERE @in_carrier_code = carrier_code )
	BEGIN
		INSERT INTO t_carrier
        (
		    carrier_code
		    ,carrier_name
		    ,scac_code
        )
		VALUES
        (
	        @in_carrier_code,
		    @in_carrier_name,
		    @in_carrier_code
		)

	SET @carrier_id = SCOPE_IDENTITY()
	SET @carrier_code = @in_carrier_code
	END
	ELSE
	BEGIN
		SELECT @carrier_id = carrier_id,@carrier_code = carrier_code
		FROM t_carrier WITH (NOLOCK)
		WHERE @in_carrier_id = carrier_id 
	END

	IF ISNULL(@carrier_code,'') = ''
		RAISERROR('Invalid Carrier',18,1)

	INSERT INTO t_appointment 
    (
	    wh_id
		,[type]
		,load_type
		,priority
		,[status]
		,trailer_id
		,location_id
		,carrier_id
		,carrier_code
		,expected_arrival
		,expected_departure
		,expected_unload
		,created
		,notes
    )
	SELECT 
		@in_wh_id AS wh_id,
		@in_appt_type As type,
		'INBOUND' AS load_type,
		@priority AS priority,
		'SCHEDULED' AS status,
		UPPER(@in_trailer) AS trailer_id,
		NULLIF(UPPER(@in_door),'') AS location_id,
		@carrier_id  AS carrier_id,
		@carrier_code AS carrier_code,
		@in_arrival AS expected_arrival,
		@in_departure AS expected_departure,
		@in_unload AS expected_unload,
		GETDATE() AS created,
		@in_comments AS comments


	
	SET @appointment = SCOPE_IDENTITY()

	INSERT INTO t_appointment_po 
    (
        appointment_id
		,po_number
		,wh_id
    )
	SELECT DISTINCT
		@appointment
		,po
		,wh_id
	FROM #pos 


	UPDATE pod
	SET earliest_delivery_date = @in_arrival
	FROM  t_appointment_po app WITH (NOLOCK)
	INNER JOIN t_po_detail pod WITH (NOLOCK) 
		ON  pod.wh_id = app.wh_id
		AND pod.po_number = app.po_number
	WHERE app.appointment_id = @appointment
	    AND earliest_delivery_date < @in_arrival

	INSERT INTO t_appt_time_slot_detail (timeslot_id, appointment_id)
	SELECT timeslot_id, @appointment
	FROM t_appt_time_slot ats WITH (NOLOCK)
	WHERE timeslot = @in_arrival
		AND wh_id = @in_wh_id
	





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
        ,location_id
        ,tran_qty
        ,generic_attribute_1
        ,comments
        ,appointment_id
    )
	SELECT 
        '105'
        ,'New Appointment'
        ,CONVERT(VARCHAR,GETDATE(),101)
        ,CONVERT(VARCHAR,GETDATE(),108)
        ,CONVERT(VARCHAR,GETDATE(),101)
        ,CONVERT(VARCHAR,GETDATE(),108)
        ,LEFT(ISNULL(dbo.usf_get_employee_from_ww_user(@in_ww_username, @in_wh_id),@in_ww_username),10)--LEFT(ISNULL((SELECT TOP 1 CAST(employee_id AS NVARCHAR) FROM t_employee WITH(NOLOCK) WHERE ww_username = @in_ww_username),@in_ww_username),10)
        ,@in_wh_id
        ,UPPER(@in_door)
        ,1
        ,RIGHT(@in_po,250)
        ,@in_comments
        ,@appointment

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
        ,comments
        ,appointment_id
        ,po_number
        ,generic_attribute_1
    )
	SELECT 
        '108'
        ,'New Appointment PO'
        ,CONVERT(VARCHAR,GETDATE(),101)
        ,CONVERT(VARCHAR,GETDATE(),108)
        ,CONVERT(VARCHAR,GETDATE(),101)
        ,CONVERT(VARCHAR,GETDATE(),108)
        ,LEFT(ISNULL(dbo.usf_get_employee_from_ww_user(@in_ww_username, @in_wh_id),@in_ww_username),10)--LEFT(ISNULL((SELECT TOP 1 CAST(employee_id AS NVARCHAR) FROM t_employee WITH(NOLOCK) WHERE ww_username = @in_ww_username),@in_ww_username),10)
        ,@in_wh_id
        ,1
        ,@in_comments
        ,@appointment
        ,po_number
        ,@in_arrival
	FROM t_appointment_po WITH (NOLOCK)
	WHERE wh_id = @in_wh_id
	    AND appointment_id = @appointment

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
