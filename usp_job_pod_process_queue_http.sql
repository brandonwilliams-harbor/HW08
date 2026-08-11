USE [AAD]
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO









ALTER PROCEDURE [dbo].[usp_job_pod_process_queue_http]
	@in_debug INT = 0
AS

BEGIN

SET NOCOUNT ON;


/****************************************************************************************************************************************************************************************
  Object: [usp_job_pod_process_queue_http]
  Description: Process the point of delivery http queue to send message for Descartes interface

ChangeLog:
 Version	Date		Intials		Repo	Notes
  -------	--------	-------		-----	-----------------------------------------------------
  1.0       20170921    STS                 Created  
  2.0       ........    BEW-HWF     HW08    Added logic to resend addPalletRequest as updatePalletRequest when returned error code "Pallet already exists." 



****************************************************************************************************************************************************************************************/
DECLARE
	@unique_id INT,
	@request_xml XML,
	@response_xml XML,
	@ms_elapsed INT,
	@http_headers XML,
	@error_msg NVARCHAR(500),
	@retries INT,
	@retries_max INT,
	@uri NVARCHAR(200),
	@timeout INT,
	@username NVARCHAR(30),
	@password NVARCHAR(30),
	@result_type nvarchar(50),
	@error_code nvarchar(10),
	@request_string varchar(max),
	@response_string varchar(max)
	
BEGIN TRY
	
	SELECT @retries_max = f1
	FROM t_control WITH (NOLOCK)
	WHERE control_type = 'POD_RETRIES'

	IF @@ROWCOUNT = 0
	BEGIN
		INSERT INTO t_control
		(	control_type,
			[description],
			allow_edit,
			f1 
		)
		SELECT
			'POD_RETRIES',
			'Max retries for POD interface',
			'Y',
			5

		SET @retries_max = 5
	END

	SELECT @timeout = f1
	FROM t_control WITH (NOLOCK)
	WHERE control_type = 'POD_TIMEOUT'

	IF @@ROWCOUNT = 0
	BEGIN
		INSERT INTO t_control
		(	control_type,
			[description],
			allow_edit,
			f1 
		)
		SELECT
			'POD_TIMEOUT',
			'Timeout for POD interface (ms)',
			'Y',
			10000

		SET @timeout = 10000
	END

	SELECT @uri = c1 + ISNULL(c2, '')
	FROM t_control WITH (NOLOCK)
	WHERE control_type = 'POD_URI'

	IF @@ROWCOUNT = 0
	BEGIN
		INSERT INTO t_control
		(	control_type,
			[description],
			allow_edit,
			c1,
			c2 
		)
		SELECT
			'POD_URI',
			'URI for POD interface',
			'Y',
			'https://harbortest.airclic.com',
			'/integration/request'

		SET @uri = 'https://harbortest.airclic.com/integration/request'
	END

	SELECT
		@username = c1,
		@password = c2
	FROM t_control WITH (NOLOCK)
	WHERE control_type = 'POD_LOGIN'

	IF @@ROWCOUNT = 0
	BEGIN
		INSERT INTO t_control
		(	
			control_type,
			[description],
			allow_edit,
			c1,
			c2 
		)
		SELECT
			'POD_LOGIN',
			'Login for POD interface',
			'Y',
			'ssmithreams',
			'airclic'

		SET @username = 'ssmithreams'
		SET @password = 'airclic'
	END

	SET @http_headers = REPLACE(REPLACE(
		'<Headers>
			<Header>
				<Key>username</Key>
				<Value>integrator</Value>
			</Header>
			<Header>
				<Key>password</Key>
				<Value>thepassword</Value>
			</Header>
		</Headers>', 'integrator', @username), 'thepassword', @password)
--2.0 Begin 
	--Find any records that failed due to "Pallet already exists error. "
	IF EXISTS 
	( 
		SELECT 1 
		FROM t_pod_queue_http WITH (NOLOCK)
		WHERE  isnull(error_msg, '') <> '' 
			AND message_type = 'addPalletRequest' 
			AND retries = 0 --only to resend when retry has not been attempted 
	)
	BEGIN 
		--set xml to update request 
		UPDATE dbo.t_pod_queue_http
		SET message_xml = CAST(
				REPLACE(
					REPLACE(
						CAST(message_xml AS NVARCHAR(MAX)),
						'<addPalletRequest',
						'<updatePalletRequest'
					),
					'</addPalletRequest>',
					'</updatePalletRequest>'
				) AS XML
			)
		WHERE message_xml.exist('/addPalletRequest') = 1
			AND message_type = 'addPalletRequest' 
			AND ISNULL(error_msg, '') <> ''
			AND retries = 0 
				
		--reset records for update processing 
		UPDATE t_pod_queue_http 
		SET queue_status = 0 
			,dt_processed = null 
			,response_xml = null 
			,error_msg = null 
			,retries = 1 
			,message_type = 'updatePalletRequest'
		WHERE ISNULL(error_msg, '') <> '' 
			AND message_type = 'addPalletRequest' 
			AND retries = 0 
	END 
--2.0 End 
	--Loop through all messages ready to process
	WHILE EXISTS
	(	
		SELECT 1
		FROM t_pod_queue_http WITH (NOLOCK)
		WHERE queue_status = 0
	)
	BEGIN
		UPDATE TOP (1) q
		SET queue_status = 1,
			@unique_id = unique_id,
			@request_xml = message_xml,
			@error_msg = NULL,
			@retries = CASE WHEN ISNULL(retries, 0) = 0 THEN 0 ELSE retries END --2.0. >> = 0  
		FROM t_pod_queue_http q
		WHERE queue_status = 0

		SET @request_string = CONVERT(VARCHAR(MAX), @request_xml)

		EXEC usp_http_generic_request
			@request_string,
			@uri,
			@timeout,
			@http_headers,
			'POST',
			@ms_elapsed out,
			@response_string out

		SELECT @response_xml = CONVERT(XML, @response_string)

		--Check if an error element was returned, this indicates a code/protocol error
		SELECT 
			@error_msg = 
				LEFT(@response_xml.value('(/error/message)[1]', 'NVARCHAR(500)'), 500)
		WHERE @response_xml.exist('/error') = 1

		IF ISNULL(@error_msg, '') <> ''
		BEGIN
			WHILE @retries < @retries_max
			BEGIN
				SET @error_msg = NULL
				SET @retries = @retries + 1

				EXEC usp_http_generic_request
					@request_string,
					@uri,
					@timeout,
					@http_headers,
					'POST',
					@ms_elapsed out,
					@response_string out

				SELECT @response_xml = CONVERT(XML, @response_string)

				--Check if an error element was returned, this indicates a code/protocol error
				SELECT 
					@error_msg = 
						LEFT(@response_xml.value('(/error/message)[1]', 'NVARCHAR(500)'), 500)
				WHERE @response_xml.exist('/error') = 1

				IF ISNULL(@error_msg, '') = ''
					BREAK
			END
		END
			
		--Check if server returned an error message
		;WITH XMLNAMESPACES (  
			'http://www.airversent.com/integration' AS i)
		SELECT
			@result_type = r.h.value('(i:resultType)[1]', 'nvarchar(50)'),
			@error_code = r.h.value('(i:errorCode)[1]', 'nvarchar(10)'),
			@error_msg = r.h.value('(i:message)[1]', 'nvarchar(500)')
		FROM @response_xml.nodes('//i:result') as r(h)
		
		IF LOWER(@result_type) = 'failure'
		BEGIN
			SET @error_msg = @error_code + ':' + @error_msg
		END
		ELSE
		BEGIN
			SET @error_msg = NULL
		END
			
		UPDATE t_pod_queue_http
		SET queue_status = CASE WHEN ISNULL(@error_msg, '') = '' THEN 2 ELSE 3 END,
			response_xml = @response_xml,
			error_msg = @error_msg,
			ms_elapsed = @ms_elapsed,
			retries = @retries,
			dt_processed = GETDATE()
		WHERE unique_id = @unique_id

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
        @ErrorMessage = 'Line=' + CONVERT(VARCHAR(12), ERROR_LINE()) + ', msg=' + ERROR_MESSAGE(),
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
