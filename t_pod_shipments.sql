USE [AAD]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[t_pod_shipments](
	[unique_id] [bigint] IDENTITY(1,1) NOT NULL,
	[wh_id] [nvarchar](10) NOT NULL,
	[customer_code] [nvarchar](20) NULL,
	[load_id] [nvarchar](30) NULL,
	[order_number] [nvarchar](30) NULL,
	[shipment_date] [datetime] NULL,
	[stop_id] [int] NULL,
	[uom_qty] [int] NULL,
	[product_type] [nvarchar](10) NULL,
	[create_date] [datetime] NULL,
 CONSTRAINT [PK_t_pod_shipments_shipments] PRIMARY KEY CLUSTERED 
(
	[unique_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80) ON [PRIMARY]
) ON [PRIMARY]
GO
