USE [AAD]
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



ALTER PROCEDURE [dbo].[usp_ww_inbound_appointment_add_po]
	@in_ww_username		NVARCHAR(MAX),
	@in_wh_id			VARCHAR(10),
	@in_appointment_id	NVARCHAR(250),
	@in_po				NVARCHAR(MAX),
	@in_comments		NVARCHAR(MAX)

AS
BEGIN
SET NOCOUNT ON;

/*********************************************************************************************************************************
Description: Add PO to Appointment, page 1710 

  Version	Date		Intials		Repo	Notes
  -------	--------	-------		------	-----------------------------------------------
  1.0       20170327    SJD                 Created 
  2.0       20260731    BEW-HWF     HW06    Added error handling for PO's that are already scheduled
  3.0		20260819	BEW-HWF		HW08	Per warehouse, they want to remove 2.0 logic 
  
*********************************************************************************************************************************/

	
	DECLARE @xml XML,
	        @employee NVARCHAR(30)

BEGIN TRY
	DECLARE 
		@error_num INT,
		@error_msg NVARCHAR(MAX),
		@error_po NVARCHAR(50),
		@arrival DATETIME

	SET @in_po =  REPLACE(REPLACE(UPPER(@in_po), CHAR(13), ''), CHAR(10), '')

	SELECT @employee = dbo.usf_get_employee_from_ww_user(@in_ww_username, @in_wh_id)

	CREATE TABLE #pos
	(
		 wh_id NVARCHAR(10)
		,po	NVARCHAR(30)
	)
	
	IF ISNULL(@in_po,'') <> ''
	BEGIN 
	SELECT
		@xml = CONVERT(XML,(CONCAT('<t>',REPLACE(@in_po,',','</t><t>'),'</t>')))

	INSERT INTO #pos (wh_id,po)
	SELECT
		 @in_wh_id						AS [wh_id]
		,LTRIM(RTRIM(t.value('.','NVARCHAR(30)')))	AS po
	FROM @xml.nodes('/t') AS x(t)



	IF EXISTS (SELECT 8 FROM #pos pos 
	          LEFT JOIN t_po_master pom WITH (NOLOCK) ON pom.po_number = pos.po AND pom.wh_id = pos.wh_id 
			  WHERE ISNULL(pom.wh_id,'') = '') 
		RAISERROR('Invalid POs',18,1)
	END
	ELSE 
		RAISERROR('Invalid POs',18,1)

	SELECT TOP 1 @error_po = pos.po
	FROM #pos pos
	INNER JOIN t_appointment_po app WITH(NOLOCK) ON pos.po = app.po_number AND pos.wh_id = app.wh_id
	WHERE app.appointment_id = @in_appointment_id
		AND app.wh_id = @in_wh_id

	IF @@ROWCOUNT > 0 
	BEGIN
		SET @error_msg = 'PO on Appointment Already ' + @error_po
		RAISERROR(@error_msg,18,1)
		GOTO EXIT_LABEL
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

	SELECT TOP 1 @error_po = pos.po 
	FROM t_po_master po WITH (NOLOCK) 
	INNER JOIN #pos pos 
		ON pos.po = po.po_number
		AND po.wh_id = pos.wh_id
	WHERE po.type <> 'PO'

	IF @@ROWCOUNT > 0 
	BEGIN
		SET @error_msg = 'PO ' + @error_po + ' for transfer'
		RAISERROR(@error_msg,18,1)
		GOTO EXIT_LABEL
	END
--3.0 Begin 
/*
--2.0 Begin 
	IF EXISTS ( SELECT 1
				FROM t_appointment_po ap WITH (NOLOCK)
				INNER JOIN t_appointment ta WITH (NOLOCK) 
					ON ap.appointment_id = ta.appointment_id
					AND ap.wh_id = ta.wh_id 
				INNER JOIN #pos pos 
					ON ap.wh_id = pos.wh_id 
					AND ap.po_number = pos.po 
				WHERE ta.[status] IN ( 'ON PREM', 'SCHEDULED', 'UNLOADED', 'UNLOADING')
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
--2.0 End 
*/ 
--3.0 End 

	INSERT INTO t_appointment_po 
	(	appointment_id
		,po_number
		,wh_id
	)
	SELECT DISTINCT
		@in_appointment_id
		,po
		,wh_id
	FROM #pos 

	IF ISNULL(@in_comments, '') <> ''
	BEGIN
		MERGE t_po_comment AS dst
		USING (SELECT wh_id AS wh_id,
				 po AS po_number,
				 @in_comments AS comment_text,
				 'A' AS comment_type,
				 0 AS sequence 
				 FROM #pos) AS src
		ON (dst.wh_id = src.wh_id 
			AND dst.po_number = src.po_number
			AND dst.comment_type = src.comment_type
			AND dst.sequence = src.sequence)
		WHEN NOT MATCHED BY TARGET 
			THEN INSERT(po_number
						,comment_type
						,comment_date
						,comment_text
						,[sequence]
						,wh_id
						)
				VALUES(  src.po_number
						,src.comment_type
						,GETDATE()
						,src.comment_text
						,src.sequence
						,src.wh_id
					)
		WHEN MATCHED
			THEN UPDATE SET 
			po_number = src.po_number
						,comment_type = src.comment_type
						,comment_date = GETDATE()
						,comment_text = RIGHT(dst.comment_text + src.comment_text,70) 
						,[sequence]	  = src.[sequence]
						,wh_id		  = src.wh_id;
	END

	SELECT @arrival = expected_arrival
	FROM t_appointment WITH (NOLOCK)
	WHERE appointment_id = @in_appointment_id

	INSERT INTO t_tran_log_holding
	(
		tran_type
		,description
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
		,ISNULL(@employee,@in_ww_username)
		,@in_wh_id
		,1
		,@in_comments
		,@in_appointment_id
		,po
		,@arrival
	FROM #pos


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
