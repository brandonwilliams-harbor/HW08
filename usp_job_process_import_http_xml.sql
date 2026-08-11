USE [AAD] 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO





ALTER PROCEDURE [dbo].[usp_job_process_import_http_xml]
	@in_debug INT = 0
AS

BEGIN

SET NOCOUNT ON;


/****************************************************************************************************************************************************************************************
  Object:
  Description: Created, Process t_import_http_xml, which is populated with event data from Airclic/Descartes

 Changelog
  Version	Date		Initials	Repo	Notes
  -------	--------	--------	------	------------------------------------------------------------------------------------------------------------------
  1.0		20190719	STS					Created
  2.0		20220602	BEW-HWF				Addded backhaul PO logic
  3.0		20221229	BEW-HWF				Added join to tote insert to exclude orders that arDEV-HJDBe not flagged to count totes
  4.0		20231215	BEW-HWF				Changed trigger type to include "Web" and "Finalize" 
  5.0		20250617	BEW-HWF				Added logic to consume data for customer signatures. Cleaned up some bad code. 
  6.0		20250703	BEW-HWF		HW03	Moved 5.0 logic to insert into database POD for customer signature captures. Added control flag to enable/disable capture of item and order data for customer signature. 
  6.1		20250728	BEW-HWF		HW03	Added Order Actual start and end datetime 
  7.0		........	BEW-HWF		HW08	Added logic to parse and insert tobacco count records into final report tables. 

************************************************************Sample Call*****************************************************************************************************************
EXEC usp_job_process_import_http_xml 1 

****************************************************************************************************************************************************************************************/
DECLARE
	@unique_id INT,
	@xml_response XML,
	@ms_elapsed INT,
	@http_headers XML,
	@error_msg NVARCHAR(500),
	@retries INT,
	@retries_max INT,
	@uri NVARCHAR(200),
	@timeout INT,
	@username NVARCHAR(30),
	@password NVARCHAR(30),
	@result_type NVARCHAR(50),
	@error_code NVARCHAR(10),
	@trigger_type NVARCHAR(50),
	@os_id INT,
	@wh_id NVARCHAR(10),
	@order_number NVARCHAR(30),
	@line_number NVARCHAR(100),
	@item_number NVARCHAR(30),
	@uom NVARCHAR(10),
	@upc NVARCHAR(80),
	@xml XML,
	@node_name1 NVARCHAR(100),
	@node_value1 NVARCHAR(100),
	@node_name2 NVARCHAR(100),
	@node_value2 NVARCHAR(100),
--7.0 Begin 
	@node_name3 NVARCHAR(100),
	@node_value3 NVARCHAR(100),
	@node_name4 NVARCHAR(100),
	@node_value4 NVARCHAR(100),
	@node_name5 NVARCHAR(100),
	@node_value5 NVARCHAR(100),
	@node_name6 NVARCHAR(100),
	@node_value6 NVARCHAR(100),
--7.0 End 
	@pod_whse NVARCHAR(30),
	@airclic_timestamp DATETIME,
	@tote_count INT,
	@tote_expected INT,
	@driver_first_name NVARCHAR(200),
	@driver_last_name NVARCHAR(200),
	@driver_username NVARCHAR(200),
	@customer_code NVARCHAR(20),
	@customer_name NVARCHAR(50),
	@route NVARCHAR(30),
	@purpose_number NVARCHAR(50),
	@totes_required TINYINT,
	@status NVARCHAR(40), --BEW 20220602
	@original_wh_id NVARCHAR(10), 
    @customer_addr NVARCHAR(50),--(5.0) Begin 
    @city nvarchar(30),
    @state nvarchar(3), 
    @zip nvarchar(12),
    @country nvarchar(5),
    @signature varbinary(max), 
    @hu_id  nvarchar(22),
    @item_description nvarchar(50),
    @item_status nvarchar(30),
    @expected_qty int,
    @accepted_qty int,
    @scan_status int,
    @service_level nvarchar(30),
    @adjusted_qty int,
    @reason_code nvarchar(30),
    @reason_description nvarchar(50),
    @pallet_number nvarchar(30), --(5.0) End
	@signature_flag INT, --(6.0)
	@actual_start_time DATETIME, --(6.1) 
	@actual_end_time DATETIME, --(6.1)
	@cig_count INT, --7.0
	@snuff_count INT, --7.0
	@ecig_count INT, --7.0
	@lil_cig_count INT,   --7.0
	@expected_cig_count	INT, 	--7.0
	@expected_snuff_count INT,--7.0
	@expected_ecig_count INT, --7.0
	@expected_lil_cig_count INT --7.0


--DECLARE @new_rma TABLE
--(
--	wh_id NVARCHAR(10),
--	order_number NVARCHAR(30),
--	rma_number NVARCHAR(30)
--)

--CREATE TABLE #order_status
--(
--	os_id INT IDENTITY(1,1),
--	order_number NVARCHAR(30),
--	pod_whse NVARCHAR(30),
--	airclic_timestamp DATETIME,
--	[route] NVARCHAR(30),
--	customer_code NVARCHAR(30),
--	customer_name NVARCHAR(50),
--	employee_id NVARCHAR(30),
--	line_number NVARCHAR(100),
--	qty_accepted INT,
--	qty_expected INT,
--	reason_code NVARCHAR(50),
--	reason_description NVARCHAR(250),
--	purpose_number NVARCHAR(50),
--	adjust_qty INT,
--	adjust_reason_code NVARCHAR(50),
--	adjust_reason_description NVARCHAR(250),
--	hj_reason_code NVARCHAR(10),
--	rma_number NVARCHAR(30),
--	item_number NVARCHAR(30),
--	uom NVARCHAR(30),
--	upc NVARCHAR(100),
--	wh_id NVARCHAR(10),
--	prefix NVARCHAR(30),
--	import_id INT,
--	processed TINYINT
--)

	
BEGIN TRY

	--Loop through all messages ready to process
	WHILE EXISTS
	(	SELECT 1
		FROM t_import_http_xml WITH (NOLOCK)
		WHERE [status] = 'N' )
			--AND response_time_ms <> 1 ) Uncomment this if need to poll Web orders 
	BEGIN
		UPDATE TOP (1) i
		SET [status] = 'P',
			@unique_id = unique_id,
			@xml_response = xml_response,
			@error_msg = NULL,
			@error_code = NULL
		FROM t_import_http_xml i
		WHERE i.[status] = 'N'
			--AND response_time_ms <> 1 Uncomment this if need to poll Web orders. Poll web orders by manually running usp_job_process_import_http_xml_2

		--Check if server returned an error message
		;WITH XMLNAMESPACES (  
			'http://www.airversent.com/integration' AS i)
		SELECT
			@result_type = r.h.value('(i:resultType)[1]', 'nvarchar(50)'),
			@error_code = r.h.value('(i:errorCode)[1]', 'nvarchar(10)'),
			@error_msg = r.h.value('(i:message)[1]', 'nvarchar(max)')
		FROM @xml_response.nodes('//i:result') as r(h)
		
		IF LOWER(@result_type) = 'failure'
		BEGIN
			SET @error_msg = @error_code + ':' + @error_msg
		END
		ELSE IF @xml_response.exist('/error') = 1
		BEGIN
			SELECT 
				@error_msg = r.h.value('(message)[1]', 'nvarchar(max)')
			FROM @xml_response.nodes('/error') as r(h)
		END
		ELSE
		BEGIN
			SET @error_msg = NULL
		END

		;WITH XMLNAMESPACES (  
			'http://www.airversent.com/integration' AS i)
		SELECT
			@trigger_type = @xml_response.value('(i:orderStatusSummaryEvent/i:trigger/@type)[1]', 'nvarchar(50)')
		
		IF ISNULL(@error_msg, '') = '' AND @trigger_type IN ('OTA', 'Finalize', 'Web') --(4.0) 
		BEGIN
			--STS 20211129 - Parse tote count
			;WITH XMLNAMESPACES (  
				'http://www.airversent.com/integration' AS i)
			SELECT
				@node_name1 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData/@name)[1]', 'nvarchar(100)'),
				@node_value1 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData)[1]', 'nvarchar(100)'),
				@node_name2 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData/@name)[2]', 'nvarchar(100)'),
				@node_value2 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData)[2]', 'nvarchar(100)'), 
				--7.0 Begin 
				@node_name3 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData/@name)[3]', 'nvarchar(100)'),
				@node_value3 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData)[3]', 'nvarchar(100)'), 
				@node_name4 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData/@name)[4]', 'nvarchar(100)'),
				@node_value4 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData)[4]', 'nvarchar(100)'),
				@node_name5 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData/@name)[5]', 'nvarchar(100)'),
				@node_value5 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData)[5]', 'nvarchar(100)'), 
				@node_name6 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData/@name)[6]', 'nvarchar(100)'),
				@node_value6 = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:stopWorkflowData)[6]', 'nvarchar(100)')
				--7.0 End 

			--Multiple stopWorkflowData nodes, ensure looking at correct one
			SELECT @tote_count = CASE WHEN @node_name1 = 'Actual Qty' THEN @node_value1 WHEN @node_name2 = 'Actual Qty' THEN @node_value2 END
			--7.0 Begin 
			SELECT @cig_count = CASE WHEN @node_name2 = 'Actual Cig Count' THEN @node_value2 WHEN @node_name3 = 'Actual Cig Count' THEN @node_value3 END 
			SELECT @snuff_count = CASE WHEN @node_name3 = 'Actual Snuff Count' THEN @node_value3 WHEN @node_name4 = 'Actual Snuff Count' THEN @node_value4 END 
			SELECT @ecig_count = CASE WHEN @node_name4 = 'Actual ECig Count' THEN @node_value4 WHEN @node_name5 = 'Actual ECig Count' THEN @node_value5 END
			SELECT @lil_cig_count = CASE WHEN @node_name5 = 'Actual LilCig Count' THEN @node_value5 WHEN @node_name6 = 'Actual LilCig Count' THEN @node_value6 END
			--7.0 End 

--(5.0) Begin, removed seperate parsing and added one big script to gather everything. 
    	;WITH XMLNAMESPACES (  
					'http://www.airversent.com/integration' AS i)
				SELECT
                --HEADER 
					@pod_whse = @xml_response.value('(i:orderStatusSummaryEvent/i:trigger/i:centerNumber)[1]', 'nvarchar(100)'), 
                    @route = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:routeNumber)[1]', 'nvarchar(30)'),
                    @status = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:status)[1]', 'nvarchar(30)'),
                    @airclic_timestamp = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:timestamp)[1]', 'nvarchar(30)'),
					@driver_first_name = @xml_response.value('(i:orderStatusSummaryEvent/i:trigger/i:employee/i:firstName)[1]', 'nvarchar(200)'),
					@driver_last_name = @xml_response.value('(i:orderStatusSummaryEvent/i:trigger/i:employee/i:lastName)[1]', 'nvarchar(200)'),					
					@order_number = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:orderNumber)[1]', 'nvarchar(30)'),
					@customer_code = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:customerInfo/i:customerNumber)[1]', 'nvarchar(20)'),
					@customer_name = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:customerInfo/i:customerName)[1]', 'nvarchar(50)'),
					@customer_addr = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:customerInfo/i:customerAddress/i:addressLine1)[1]', 'nvarchar(50)'),
                    @state = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:customerInfo/i:customerAddress/i:state)[1]', 'nvarchar(3)'),
                    @city = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:customerInfo/i:customerAddress/i:city)[1]', 'nvarchar(30)'),
					@zip = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:customerInfo/i:customerAddress/i:zipCode)[1]', 'nvarchar(12)'),
					@country = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:customerInfo/i:customerAddress/i:country)[1]', 'nvarchar(5)'),
                    @customer_addr = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:customerInfo/i:customerAddress/i:addressLine1)[1]', 'nvarchar(50)'),
                    @signature = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:orderItemStatusGroup/i:recipient/i:signature)[1]', 'VARBINARY(MAX)'), 
                    @purpose_number = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusSummary/i:serviceSummary/i:serviceSummaryEntry/i:purposeNumber)[1]', 'nvarchar(50)'),
                    @driver_username = @xml_response.value('(i:orderStatusSummaryEvent/i:trigger/i:employee/i:username)[1]', 'nvarchar(200)'),
					@actual_start_time = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:actualStart)[1]', 'nvarchar(30)'), --(6.1) 
					@actual_end_time = @xml_response.value('(i:orderStatusSummaryEvent/i:orderStatusDetail/i:visit/i:service/i:actualEnd)[1]', 'nvarchar(30)') --(6.1) 

                --set the actual wh id 
				SELECT @wh_id = wh_id
				FROM t_whse WITH (NOLOCK)
				WHERE pod_whse = @pod_whse

                --If 
                IF @service_level = 'Pallet'
                BEGIN   
                    SET @hu_id = @pallet_number 
                END 

                IF @hu_id LIKE '%GS1'
                BEGIN
                    SET @hu_id = SUBSTRING(@hu_id,1,8 ) 
                END 

			--(6.0) Begin 
				--pod control flag for signature data 
				SELECT @signature_flag = c1
				FROM t_control WITH (NOLOCK) 
				WHERE control_type = 'POD_SIGN_FLAG' 

				IF @@ROWCOUNT = 0
				BEGIN 
					SET @signature_flag = 0 
				END 
			--(6.0) End 
                IF @in_debug = 1
                BEGIN   
					SELECT @actual_start_time as actual_start_time 
                    select @hu_id as hu_id, @item_description as descr , @reason_code as reason_Code, @service_level as service_level  
                END 

    --(5.0) End 

	--7.0 Begin 
		--Set expected cig counts 
		SELECT @expected_cig_count = uom_qty 
		FROM t_pod_shipments WITH (NOLOCK)
		WHERE product_type = 'CIG' 
			AND wh_id = @wh_id 
			AND order_number = @order_number 

		SELECT @expected_snuff_count = uom_qty 
		FROM t_pod_shipments WITH (NOLOCK)
		WHERE product_type = 'SNF' 
			AND wh_id = @wh_id 
			AND order_number = @order_number 		

		SELECT @expected_ecig_count = uom_qty 
		FROM t_pod_shipments WITH (NOLOCK)
		WHERE product_type = 'ECIG' 
			AND wh_id = @wh_id 
			AND order_number = @order_number 	

		SELECT @expected_lil_cig_count = uom_qty 
		FROM t_pod_shipments WITH (NOLOCK)
		WHERE product_type = 'LILCIG' 
			AND wh_id = @wh_id 
			AND order_number = @order_number 	

	--7.0 End 

			--A tote count was returned
			IF @tote_count IS NOT NULL 
			BEGIN
				--Check whether customer requires totes
				SELECT @totes_required = totes_required
				FROM t_customer WITH (NOLOCK)
				WHERE customer_code = @customer_code

				--Product pickup are returns or customer does not require totes, do not process
				IF ISNULL(@purpose_number, '') <> 'Product Pickup' AND ISNULL(@totes_required, 0) = 1 AND ISNULL(@purpose_number, '') <> 'Backhaul'
				BEGIN
					--Get actual wh_id
					SELECT @wh_id = wh_id
					FROM t_whse WITH (NOLOCK)
					WHERE pod_whse = @pod_whse

					SELECT TOP 1 @tote_expected = tote_expected
					FROM t_customer_totes WITH (NOLOCK)
					WHERE wh_id = @wh_id
					AND customer_code = @customer_code
					ORDER BY unique_id DESC

				IF @in_debug = 1 
				BEGIN 
					SELECT 'order_number ', @order_number
					SELECT 'POD_whse ', @pod_whse
					SELECT	'wh_id ', @wh_id 
					SELECT 'tote_expect ', @tote_expected 
				END 

					INSERT INTO t_tote_tracking_airclic
					(	wh_id,
						driver_first_name,
						driver_last_name,
						driver_username,
						order_number,
						customer_code,
						customer_name,
						[route],
						tote_count,
						tote_expected,
						airclic_timestamp,
						create_date,
						import_id )
					SELECT
						@wh_id,
						@driver_first_name,
						@driver_last_name,
						@driver_username,
						@order_number,
						@customer_code, 
						@customer_name,
						@route,
						@tote_count,
						ISNULL(@tote_expected, 0),
						@airclic_timestamp,
						GETDATE(),
						@unique_id
					--(5.0) Removed order join and added below WHERE statement. Order would fail if did not exist in t_order. 
					WHERE NOT EXISTS (SELECT 1 FROM t_order o1 WITH (NOLOCK) WHERE o1.order_number = @order_number AND o1.wh_id = @wh_id AND ISNULL(o1.tote_count_flag, 0) = 0) 
						AND NOT EXISTS ( SELECT 1 
										  FROM t_tote_tracking_airclic ta WITH (NOLOCK)
										  WHERE @order_number = ta.order_number
										  	AND @wh_id = ta.wh_id )   
						
				END
			END

		--Backhauls 
			IF @purpose_number = 'Backhaul' --grab backhaul @order_number LIKE 'P%'--exclude PO's
			BEGIN
				--get PO original Whs. RDC can pick-up LDC PO on backhaul. vice versa 
				select @original_wh_id = wh_id
				FROM t_po_master WITH (NOLOCK)
				WHERE po_number = @order_number

				UPDATE t_po_master 
				SET received_by_airclic = 1 
				where po_number = @order_number 

				SET @status = CASE WHEN @status = 'fulfilled' THEN 'COMPLETE' ELSE 'INCOMPLETE' END 

				INSERT INTO t_po_backhaul_airclic
					(	wh_id,
						original_wh_id,
						driver_first_name,
						driver_last_name,
						driver_username,
						po_number,
						vendor_code,
						vendor_name,
						[status],
						[route],
						airclic_timestamp,
						create_date,
						import_id
						)
					SELECT DISTINCT 
						@wh_id,
						@original_wh_id,
						@driver_first_name,
						@driver_last_name,
						@driver_username,
						@order_number,
						@customer_code, 
						@customer_name,
						@status,
						@route,
						@airclic_timestamp,
						GETDATE(),
						@unique_id
					--(5.0) Added where clause below 
					WHERE NOT EXISTS (SELECT 1 FROM t_po_backhaul_airclic WITH (NOLOCK) WHERE wh_id = @wh_id AND po_number = @order_number AND CAST(GETDATE() AS DATE) = CAST(create_date AS DATE))
			END 

--(5.0) Begin
		--(6.0) Flag added 
		IF @signature_flag = 1 
		BEGIN 
			INSERT INTO [POD].[dbo].t_pod_header --(6.0) 
				( 
					[wh_id]              
					,[create_date]        
					,[route]              
					,[order_timestamp]    
					,[order_status]       
					,[driver_first_name]  
					,[driver_last_name]   
					,[order_number]       
					,[customer_code]      
					,[customer_name]      
					,[customer_addr]      
					,[city]               
					,[state]              
					,[zip]                
					,[country]            
					,[customer_signature] 
					,[processed]          
					,[processed_timestamp]
					,[import_id]
					,actual_start_time --(6.1) 
					,actual_end_time --(6.1) 
					,cig_count       		--7.0 Begin 	
					,snuff_count	
					,ecig_count 	
					,lil_cig_count 	
					,expected_cig_count	
					,expected_snuff_count
					,expected_ecig_count 
					,expected_lil_cig_Count --7.0 End 
				)
			SELECT DISTINCT 
				@wh_id
				,GETDATE()
				,@route
				,@airclic_timestamp
				,@status
				,@driver_first_name
				,@driver_last_name
				,@order_number
				,@customer_code
				,@customer_name
				,@customer_addr
				,@city
				,@state
				,@zip
				,@country
				,@signature
				,0
				,''
				,@unique_id 
				,@actual_start_time --(6.1) 
				,@actual_end_time --(6.1) 
				,ISNULL(@cig_count, 0)    	--7.0 Begin 
				,ISNULL(@snuff_count, 0) 	
				,ISNULL(@ecig_count, 0)	
				,ISNULL(@lil_cig_count, 0)  	
				,ISNULL(@expected_cig_count, 0) 
				,ISNULL(@expected_snuff_count, 0)
				,ISNULL(@expected_ecig_count, 0) 
				,ISNULL(@expected_lil_cig_count, 0) --7.0 End 
			WHERE NOT EXISTS (SELECT 1 FROM [POD].[dbo].t_pod_header WITH (NOLOCK) WHERE order_number = @order_number AND wh_id = @wh_id )

		;WITH XMLNAMESPACES (
				'http://www.airversent.com/integration' AS ig 
			)
			SELECT
				r2.h2.value('(*:palletNumber)[1]','varchar(50)') as container_id, --update later 
				r1.h1.value('(*:lineNumber)[1]', 'VARCHAR(20)') as line_number, 
				r2.h2.value('@lineNumber', 'VARCHAR(20)') AS pod_line_number, 
				r1.h1.value('(*:description)[1]','varchar(200)') as item_description,
				r1.h1.value('(*:status)[1]','varchar(50)') as item_status, 
				r1.h1.value('(*:expectedQuantity)[1]', 'INT') as expected_qty,
				r1.h1.value('(*:acceptedQuantity)[1]', 'INT') as accepted_qty, 
				r1.h1.value('(*:scanned)[1]', 'BIT') as scan_status, 
				r1.h1.value('(*:serviceLevel)[1]', 'VARCHAR(50)') as service_level, --update value later for item and tote.container
				r1.h1.value('(*:adjustment/*:adjustQuantity)[1]', 'int') as adjusted_qty,
				r1.h1.value('(*:adjustment/*:reason/*:reasonCode)[1]', 'nvarchar(50)') as reason_code,
				r1.h1.value('(*:adjustment/*:reason/*:reasonDescription)[1]', 'nvarchar(250)') as reason_description
			INTO #temp_details 
			FROM @xml_response.nodes('/*:orderStatusSummaryEvent/*:orderStatusSummary') as r(h)
			CROSS APPLY r.h.nodes('*:orderItemStatusGroup/*:orderItemStatusSummary') as r1(h1)
			OUTER APPLY @xml_response.nodes('/*:orderStatusSummaryEvent/*:orderStatusDetail/*:visit/*:service/*:receipt') AS r2(h2)
			where r1.h1.value('(*:lineNumber)[1]', 'nvarchar(100)') = r2.h2.value('@lineNumber', 'VARCHAR(20)')

			UPDATE #temp_details 
			SET service_level = case WHEN service_level = 'Pallet' THEN 'Container' ELSE service_level END
				--container_id = CASE WHEN service_level = 'Pallet' THEN   

			INSERT INTO [POD].[dbo].t_pod_detail --(6.0) 
				(
					[wh_id]
					,[order_number]
					,[customer_code]
					,[container_id] 
					,[line_number]
					,[item_description]
					,[delivery_status]
					,[expected_qty]
					,[accepted_qty]
					,[scan_status]
					,[service_level]
					--,[voided]
					,[adjusted_qty]
					,[reason_code]
					,[reason_description]
					,[processed]          
				) 
			SELECT @wh_id 
					,@order_number
					,@customer_code
					,CASE WHEN container_id LIKE '%-GS1' THEN LEFT(container_id, LEN(container_id) -4) ELSE container_id END  --strip GS1 from hu_id
					,line_number 
					,item_description
					,item_status
					,expected_qty
					,accepted_qty
					,scan_status
					,service_level
					,adjusted_qty
					,reason_code
					,reason_description
					,0 
			FROM #temp_details d1 
			WHERE NOT EXISTS (SELECT 1 FROM [POD].[dbo].t_pod_detail d2 WITH (NOLOCK) WHERE d2.order_number = @order_number AND  d2.wh_id = @wh_id )

			DROP TABLE #temp_details 
		END 

--(5.0) End 

			-- STS 20211129 - Commenting out RMA logic, future functionality
			--DELETE #order_status
			
			--INSERT INTO #order_status
			--SELECT
			--	r.h.value('(*:orderNumber)[1]','nvarchar(30)'),
			--	r.h.value('(*:centerNumber)[1]','nvarchar(30)'),
			--	r.h.value('(*:timestamp)[1]','datetime'),
			--	r.h.value('(*:routeNumber)[1]','nvarchar(30)'),
			--	r.h.value('(*:customerInfo/*:customerNumber)[1]','nvarchar(30)'),
			--	r.h.value('(*:customerInfo/*:customerName)[1]','nvarchar(50)'),
			--	r.h.value('(*:orderItemStatusGroup/*:employee/*:username)[1]','nvarchar(30)'),
			--	r1.h1.value('(*:lineNumber)[1]', 'nvarchar(100)'),
			--	r1.h1.value('(*:acceptedQuantity)[1]', 'int'),
			--	r1.h1.value('(*:expectedQuantity)[1]', 'int'),
			--	r1.h1.value('(*:createdOnClient/*:reason/*:reasonCode)[1]', 'nvarchar(50)'),
			--	r1.h1.value('(*:createdOnClient/*:reason/*:reasonDescription)[1]', 'nvarchar(250)'),
			--	r1.h1.value('(*:purposeNumber)[1]', 'nvarchar(50)'),
			--	r1.h1.value('(*:adjustment/*:adjustQuantity)[1]', 'int'),
			--	r1.h1.value('(*:adjustment/*:reason/*:reasonCode)[1]', 'nvarchar(50)'),
			--	r1.h1.value('(*:adjustment/*:reason/*:reasonDescription)[1]', 'nvarchar(250)'),
			--	NULL, --hj_reason_code
			--	NULL, --rma_number
			--	NULL, --item_number
			--	NULL, --uom
			--	NULL, --upc
			--	NULL, --wh_id
			--	NULL, --prefix
			--	@unique_id,
			--	0 --processed
			--FROM @xml_response.nodes('/*:orderStatusSummaryEvent/*:orderStatusSummary') as r(h)
			--CROSS APPLY r.h.nodes('*:orderItemStatusGroup/*:orderItemStatusSummary') as r1(h1)
			
			--IF @in_debug = 1
			--BEGIN
			--	SELECT '#order_status',* FROM #order_status
			--END
			
			----If product was not accepted for an order (damaged for example)
			----It will come back with an adjustment quantity but not a purpose number
			----Update fields for consistent logic below
			--UPDATE #order_status
			--SET purpose_number = '18',
			--	qty_expected = adjust_qty * -1,
			--	qty_accepted = adjust_qty * -1,
			--	reason_code = adjust_reason_code,
			--	reason_description = adjust_reason_description
			--WHERE adjust_qty < 0
			--	--AND qty_accepted <= 0 --BEW 20200925
			--	and purpose_number <> 'Product Pickup' ----BEW 20200925 preplanned pickups already have qty accepted. 

			----If not a returns purpose remove from the table
			--DELETE FROM #order_status
			--WHERE purpose_number NOT IN ('Product Pickup', '18')

			----Get HighJump warehouse from POD whse
			--UPDATE os
			--SET wh_id = w.wh_id
			--FROM #order_status os
			--INNER JOIN t_whse w WITH (NOLOCK)
			--	ON os.pod_whse = w.pod_whse

			----Get HighJump reason code
			--UPDATE os
			--SET hj_reason_code = reason_id
			--FROM #order_status os
			--INNER JOIN t_reason r
			--	ON os.reason_code = r.reason_id
			--	AND r.type = 'RETURNS'

			----For lines that already have an RMA number, get the RMA number and clear order number as an actual RMA number was sent
			--UPDATE os
			--SET rma_number = rma.rma_number,
			--	order_number = NULL
			--FROM #order_status os
			--INNER JOIN t_rma_master rma WITH (NOLOCK)
			--	ON os.order_number = rma.rma_number
			--	AND os.wh_id = rma.wh_id

			----If not a valid HighJump reason code and not a known RMA do not process the record
			--DELETE FROM #order_status
			--WHERE hj_reason_code IS NULL
			--AND rma_number IS NULL

			----For ad hoc returns the line number contains a UPC
			--UPDATE os
			--SET item_number = upc.item_number,
			--	uom = upc.uom,
			--	upc = upc.upc
			--FROM #order_status os
			--INNER JOIN t_item_upc upc WITH (NOLOCK)
			--	ON os.line_number = upc.upc
			--	AND os.wh_id = upc.wh_id
			--WHERE os.rma_number IS NULL

			----For ad hoc returns the line number can also contain an item number
			--UPDATE os
			--SET item_number = itm.item_number,
			--	uom = itm.purchase_uom
			--FROM #order_status os
			--INNER JOIN t_item_master itm WITH (NOLOCK)
			--	ON os.line_number = itm.item_number
			--	AND os.wh_id = itm.wh_id
			--WHERE os.rma_number IS NULL
			--AND os.item_number IS NULL

			----Special handling for adjustments to find item number
			--WHILE EXISTS (SELECT 1 FROM #order_status WHERE adjust_qty < 1 AND processed = 0)
			--BEGIN
			--	SELECT TOP 1
			--		@os_id = os_id,
			--		@wh_id = wh_id,
			--		@order_number = order_number,
			--		@line_number = line_number,
			--		@item_number = NULL,
			--		@uom = NULL
			--	FROM #order_status
			--	WHERE adjust_qty < 1 AND processed = 0

			--	--LPNs sometimes appended with -GS1
			--	SET @line_number = REPLACE(@line_number, '-GS1', '')
				
			--	--The line number may be populated with the picked LPN, ensure it is unique match (not a tote)
			--	IF 1 <
			--	(	SELECT COUNT(1)
			--		FROM t_pick_detail WITH (NOLOCK)
			--		WHERE wh_id = @wh_id
			--		AND order_number = @order_number
			--		AND container_id = @line_number )				
			--	BEGIN
			--		--Can't find a unique item number
			--		UPDATE #order_status
			--		SET processed = 1
			--		WHERE os_id = @os_id
			--		CONTINUE
			--	END

			--	SELECT
			--		@item_number = item_number,
			--		@uom = uom
			--	FROM t_pick_detail WITH (NOLOCK)
			--	WHERE wh_id = @wh_id
			--	AND order_number = @order_number
			--	AND (container_id = @line_number OR line_number = @line_number)

			--	UPDATE #order_status
			--	SET processed = 1,
			--		item_number = @item_number,
			--		uom = @uom
			--	WHERE os_id = @os_id
			--END

			----Loop to attempt to GS1 parse anything where we didn't find an item
			--WHILE EXISTS (SELECT 1 FROM #order_status WHERE processed = 0 AND item_number IS NULL)
			--BEGIN
			--	SELECT TOP 1
			--		@os_id = os_id,
			--		@wh_id = wh_id,
			--		@line_number = line_number,
			--		@item_number = NULL,
			--		@uom = NULL,
			--		@upc = NULL
			--	FROM #order_status
			--	WHERE processed = 0 AND item_number IS NULL

			--	BEGIN TRY 
			--		EXEC usp_parse_gs1 @line_number, @xml out				

			--		SELECT @upc = value
			--		FROM
			--		(	SELECT
			--			r.h.value('(AI)[1]', 'NVARCHAR(2)') as tag,
			--			r.h.value('(Value)[1]', 'NVARCHAR(100)') as value
			--		FROM @xml.nodes('/CodeList/CodeList/Code') as r(h) ) t 
			--		WHERE tag = '01'

			--		IF @@ROWCOUNT > 0
			--		BEGIN
			--			SELECT TOP 1
			--				@item_number = item_number,
			--				@uom = uom
			--			FROM t_item_upc WITH (NOLOCK)
			--			WHERE wh_id = @wh_id
			--			AND upc = @upc
			--		END
			--	END TRY
			--	BEGIN CATCH
			--		PRINT 'GS1 parsing error'
			--	END CATCH

			--	UPDATE #order_status
			--	SET processed = 1,
			--		item_number = @item_number,
			--		uom = @uom,
			--		upc = @upc
			--	WHERE os_id = @os_id

			--END

			----Get prefix for generating new RMA
			--UPDATE os
			--SET prefix = whc.c1
			--FROM #order_status os
			--INNER JOIN t_whse_control whc WITH (NOLOCK)
			--	ON os.wh_id = whc.wh_id
			--	AND whc.control_type = 'RMA_NUMBER'
			--WHERE os.rma_number IS NULL

			--DELETE @new_rma

			--INSERT INTO @new_rma
			--SELECT
			--	os.wh_id, os.order_number, 
			--	ISNULL(os.prefix, 'RTN') + RIGHT('000' +  CONVERT(VARCHAR(7), NEXT VALUE FOR RMA_NUMBER), 7) as rma_number					
			--FROM #order_status os
			--WHERE os.rma_number IS NULL
			--AND os.hj_reason_code IS NOT NULL --Must have HighJump reason code to create a return
			--AND os.item_number IS NOT NULL --Must be able to match UPC to HighJump item number
			--GROUP BY os.order_number, os.wh_id, os.prefix
			
			----Lines without matching RMA, generate a new RMA
			--UPDATE os
			--SET rma_number = nr.rma_number
			--FROM #order_status os
			--INNER JOIN @new_rma nr
			--	ON os.order_number = nr.order_number
			--	AND os.wh_id = nr.wh_id
			--WHERE os.rma_number IS NULL
			--AND os.hj_reason_code IS NOT NULL --Must have HighJump reason code to create a return
			--AND os.item_number IS NOT NULL --Must be able to match UPC to HighJump item number
			
			--IF @in_debug = 1
			--BEGIN
			--	SELECT '@new_rma',* FROM @new_rma
			--	SELECT '#order_status with new RMA', *
			--	FROM #order_status os
			--	INNER JOIN ( SELECT DISTINCT rma_number FROM @new_rma) nr
			--		ON os.rma_number = nr.rma_number
			--END
			
			----Generate new line numbers
			--UPDATE os
			--SET line_number = CONCAT(t.line_number, '000')
			--FROM #order_status os
			--INNER JOIN
			--(	SELECT
			--		os.rma_number, os.item_number, os.wh_id, 
			--		ROW_NUMBER() OVER (PARTITION BY os.rma_number, os.wh_id ORDER BY os.item_number ) as line_number
			--	FROM #order_status os
			--	INNER JOIN ( SELECT DISTINCT rma_number FROM @new_rma) nr
			--		ON os.rma_number = nr.rma_number
			--	WHERE os.hj_reason_code IS NOT NULL --Must have HighJump reason code to create a return
			--	AND os.item_number IS NOT NULL --Must be able to match UPC to HighJump item number
			--	GROUP BY os.rma_number, os.item_number, os.wh_id
			--) t
			--	ON os.rma_number = t.rma_number
			--	AND os.item_number = t.item_number
			--	AND os.wh_id = t.wh_id
			
			--IF @in_debug = 1
			--BEGIN
			--	SELECT '#order_status AFTER',* FROM #order_status
			--END

			----Create RMAs for ad hoc returns from Airclic
			--INSERT INTO t_rma_master
			--(	rma_number,
			--	wh_id,
			--	order_date,
			--	create_date,
			--	customer_code,
			--	customer_name,
			--	status,
			--	user_rma,
			--	sent_to_airclic	)
			--SELECT
			--	os.rma_number,
			--	os.wh_id,
			--	GETDATE(),
			--	GETDATE(),
			--	os.customer_code,
			--	os.customer_name,
			--	'OPEN',
			--	1,
			--	1
			--FROM #order_status os
			--INNER JOIN ( SELECT DISTINCT rma_number FROM @new_rma) nr
			--	ON os.rma_number = nr.rma_number
			--GROUP BY
			--	os.rma_number,
			--	os.wh_id,
			--	os.customer_code,
			--	os.customer_name

			--INSERT INTO t_rma_detail
			--(	rma_number,
			--	wh_id,
			--	line_number,
			--	item_number,
			--	uom,
			--	qty,
			--	reason_code,
			--	miss_picked_item,
			--	rcvd_by_airclic	)
			--SELECT
			--	os.rma_number,
			--	os.wh_id,
			--	os.line_number,
			--	os.item_number,
			--	os.uom,
			--	SUM(os.qty_expected) * iu.conversion_factor,
			--	os.hj_reason_code,
			--	0,
			--	1
			--FROM #order_status os
			--INNER JOIN ( SELECT DISTINCT rma_number FROM @new_rma) nr
			--	ON os.rma_number = nr.rma_number
			--INNER JOIN t_item_uom iu WITH (NOLOCK)
			--	ON os.item_number = iu.item_number
			--	AND os.uom = iu.uom
			--	AND os.wh_id = iu.wh_id
			--WHERE os.hj_reason_code IS NOT NULL --Must have HighJump reason code to create a return
			--AND os.item_number IS NOT NULL --Must be able to match UPC to HighJump item number
			--GROUP BY
			--	os.rma_number,
			--	os.wh_id,
			--	os.line_number,
			--	os.item_number,
			--	os.uom,
			--	os.hj_reason_code,
			--	iu.conversion_factor

			--INSERT INTO t_rma_airclic
			--(	wh_id,
			--	rma_number,
			--	order_number,
			--	customer_code,
			--	customer_name,
			--	line_number,
			--	item_number,
			--	upc,
			--	variant_code,
			--	qty_returned,
			--	qty_expected,
			--	uom,
			--	reason_code,
			--	reason_description,
			--	route,
			--	employee_id,
			--	airclic_timestamp,
			--	create_date,
			--	import_id )
			--SELECT
			--	w.wh_id,
			--	os.rma_number,
			--	os.order_number,
			--	os.customer_code,
			--	os.customer_name,
			--	os.line_number,
			--	ISNULL(rmad.item_number, 'Unknown'),
			--	os.upc,
			--	rmad.variant_code,
			--	os.qty_accepted,
			--	os.qty_expected,
			--	rmad.uom,
			--	os.reason_code,
			--	os.reason_description,
			--	os.route,
			--	os.employee_id,
			--	os.airclic_timestamp,
			--	GETDATE(),
			--	@unique_id
			--FROM #order_status os
			--INNER JOIN t_whse w WITH (NOLOCK)
			--	ON os.pod_whse = w.pod_whse
			--LEFT OUTER JOIN t_rma_detail rmad WITH (NOLOCK)
			--	ON os.rma_number = rmad.rma_number
			--	AND os.line_number = rmad.line_number
			--	AND w.wh_id = rmad.wh_id

			--UPDATE rmad
			--SET rcvd_by_airclic = 1
			--FROM #order_status os
			--INNER JOIN t_whse w WITH (NOLOCK)
			--	ON os.pod_whse = w.pod_whse
			--INNER JOIN t_rma_detail rmad WITH (NOLOCK)
			--	ON os.order_number = rmad.rma_number
			--	AND os.line_number = rmad.line_number
			--	AND w.wh_id = rmad.wh_id
			--WHERE os.purpose_number IN ('Product Pickup', '18')
		END
		
		--This error code indicates a timeout which means Airclic had no events to send
		IF @error_code = '41001'
		BEGIN
			DELETE t_import_http_xml
			WHERE unique_id = @unique_id
		END
		ELSE
		BEGIN
			UPDATE t_import_http_xml
			SET status = CASE WHEN ISNULL(@error_msg, '') = '' THEN 'C' ELSE 'E' END,
				error_msg = @error_msg,
				dt_processed = GETDATE()
			WHERE unique_id = @unique_id
		END
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
