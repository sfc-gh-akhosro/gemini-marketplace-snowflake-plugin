-- =============================================================================
-- Snowflake plugin for Gemini Agent: backend setup
-- Creates GEMINI_DEMO.TPCH (data, semantic view, search, agent, write procs),
-- the MCP server, and the OAuth integration used by Gemini.
-- Run as ACCOUNTADMIN. Safe to re-run.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 1. Warehouse, role, database
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS GEMINI_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;

-- Role used by Gemini testers through OAuth (read + ticket writes only)
CREATE ROLE IF NOT EXISTS GEMINI_PLUGIN_ROLE;
GRANT ROLE GEMINI_PLUGIN_ROLE TO ROLE SYSADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE GEMINI_PLUGIN_ROLE;
GRANT USAGE ON WAREHOUSE GEMINI_WH TO ROLE GEMINI_PLUGIN_ROLE;

CREATE DATABASE IF NOT EXISTS GEMINI_DEMO;
CREATE SCHEMA IF NOT EXISTS GEMINI_DEMO.TPCH;
GRANT USAGE ON DATABASE GEMINI_DEMO TO ROLE GEMINI_PLUGIN_ROLE;
GRANT USAGE ON SCHEMA GEMINI_DEMO.TPCH TO ROLE GEMINI_PLUGIN_ROLE;

USE WAREHOUSE GEMINI_WH;
USE SCHEMA GEMINI_DEMO.TPCH;

-- -----------------------------------------------------------------------------
-- 2. TPC-H data (SF1 copy from SNOWFLAKE_SAMPLE_DATA)
--    If the sample database isn't mounted, find the share with
--    SHOW SHARES LIKE '%SAMPLE%' and run, for example:
--    CREATE DATABASE SNOWFLAKE_SAMPLE_DATA FROM SHARE SFSALESSHARED.SFC_SAMPLES_GCPUSCENTRAL1.SAMPLE_DATA;
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE REGION   AS SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.REGION;
CREATE OR REPLACE TABLE NATION   AS SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.NATION;
CREATE OR REPLACE TABLE CUSTOMER AS SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.CUSTOMER;
CREATE OR REPLACE TABLE ORDERS   AS SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS;
CREATE OR REPLACE TABLE LINEITEM AS SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.LINEITEM;
CREATE OR REPLACE TABLE PART     AS SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.PART;
CREATE OR REPLACE TABLE PARTSUPP AS SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.PARTSUPP;
CREATE OR REPLACE TABLE SUPPLIER AS SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.SUPPLIER;

GRANT SELECT ON ALL TABLES IN SCHEMA GEMINI_DEMO.TPCH TO ROLE GEMINI_PLUGIN_ROLE;

-- -----------------------------------------------------------------------------
-- 3. Support tickets (target of the write tools)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE SUPPORT_TICKET_SEQ START = 1006;

CREATE OR REPLACE TABLE SUPPORT_TICKETS (
  TICKET_ID     STRING        NOT NULL PRIMARY KEY,
  CUSTOMER_KEY  NUMBER        NOT NULL,
  CATEGORY      STRING        NOT NULL,
  PRIORITY      STRING        NOT NULL,
  STATUS        STRING        NOT NULL,
  DESCRIPTION   STRING,
  REASON        STRING,
  CREATED_AT    TIMESTAMP_LTZ NOT NULL,
  UPDATED_AT    TIMESTAMP_LTZ NOT NULL
);

-- Resets tickets T-1001..T-1005 to the golden dataset preconditions.
-- Not exposed through MCP; run before each evaluation pass.
CREATE OR REPLACE PROCEDURE RESET_DEMO_TICKETS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  DELETE FROM GEMINI_DEMO.TPCH.SUPPORT_TICKETS;
  INSERT INTO GEMINI_DEMO.TPCH.SUPPORT_TICKETS VALUES
    ('T-1001', 1234, 'damaged_item',  'medium', 'OPEN',     'Order arrived damaged',          NULL, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('T-1002', 5678, 'late_delivery', 'high',   'OPEN',     'Shipment is two weeks late',     NULL, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('T-1003', 42,   'billing',       'low',    'RESOLVED', 'Invoice total question',         NULL, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('T-1004', 900,  'return',        'medium', 'OPEN',     'Needs a return label',           NULL, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('T-1005', 77,   'wrong_item',    'medium', 'OPEN',     'Received the wrong part number', NULL, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
  RETURN 'Demo tickets reset';
END;
$$;

CALL RESET_DEMO_TICKETS();

GRANT SELECT ON TABLE SUPPORT_TICKETS TO ROLE GEMINI_PLUGIN_ROLE;

CREATE OR REPLACE PROCEDURE CREATE_SUPPORT_TICKET(
  CUSTOMER_KEY NUMBER,
  CATEGORY     STRING,
  DESCRIPTION  STRING,
  PRIORITY     STRING DEFAULT 'medium'
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_category STRING DEFAULT LOWER(TRIM(:CATEGORY));
  v_priority STRING DEFAULT LOWER(TRIM(COALESCE(:PRIORITY, 'medium')));
  v_exists   NUMBER;
  v_id       STRING;
BEGIN
  IF (v_category NOT IN ('damaged_item', 'late_delivery', 'billing', 'return', 'wrong_item', 'other')) THEN
    RETURN OBJECT_CONSTRUCT('error', 'Invalid category. Use one of: damaged_item, late_delivery, billing, return, wrong_item, other');
  END IF;
  IF (v_priority NOT IN ('low', 'medium', 'high', 'critical')) THEN
    RETURN OBJECT_CONSTRUCT('error', 'Invalid priority. Use one of: low, medium, high, critical');
  END IF;
  SELECT COUNT(*) INTO :v_exists FROM GEMINI_DEMO.TPCH.CUSTOMER WHERE C_CUSTKEY = :CUSTOMER_KEY;
  IF (v_exists = 0) THEN
    RETURN OBJECT_CONSTRUCT('error', 'Customer ' || :CUSTOMER_KEY || ' not found');
  END IF;

  SELECT 'T-' || GEMINI_DEMO.TPCH.SUPPORT_TICKET_SEQ.NEXTVAL INTO :v_id;
  INSERT INTO GEMINI_DEMO.TPCH.SUPPORT_TICKETS
    (TICKET_ID, CUSTOMER_KEY, CATEGORY, PRIORITY, STATUS, DESCRIPTION, CREATED_AT, UPDATED_AT)
  VALUES (:v_id, :CUSTOMER_KEY, :v_category, :v_priority, 'OPEN', :DESCRIPTION, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

  RETURN OBJECT_CONSTRUCT('ticket_id', v_id, 'customer_key', CUSTOMER_KEY, 'category', v_category,
                          'priority', v_priority, 'status', 'OPEN');
END;
$$;

CREATE OR REPLACE PROCEDURE UPDATE_TICKET_STATUS(
  TICKET_ID STRING,
  STATUS    STRING,
  REASON    STRING DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_status STRING DEFAULT UPPER(TRIM(:STATUS));
  v_old    STRING;
BEGIN
  IF (v_status NOT IN ('OPEN', 'ON_HOLD', 'ESCALATED', 'RESOLVED', 'CLOSED')) THEN
    RETURN OBJECT_CONSTRUCT('error', 'Invalid status. Use one of: OPEN, ON_HOLD, ESCALATED, RESOLVED, CLOSED');
  END IF;
  SELECT MAX(STATUS) INTO :v_old FROM GEMINI_DEMO.TPCH.SUPPORT_TICKETS WHERE TICKET_ID = :TICKET_ID;
  IF (v_old IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('error', 'Ticket ' || :TICKET_ID || ' not found');
  END IF;

  UPDATE GEMINI_DEMO.TPCH.SUPPORT_TICKETS
     SET STATUS = :v_status, REASON = COALESCE(:REASON, REASON), UPDATED_AT = CURRENT_TIMESTAMP()
   WHERE TICKET_ID = :TICKET_ID;

  RETURN OBJECT_CONSTRUCT('ticket_id', TICKET_ID, 'previous_status', v_old, 'status', v_status, 'reason', REASON);
END;
$$;

GRANT USAGE ON PROCEDURE CREATE_SUPPORT_TICKET(NUMBER, STRING, STRING, STRING) TO ROLE GEMINI_PLUGIN_ROLE;
GRANT USAGE ON PROCEDURE UPDATE_TICKET_STATUS(STRING, STRING, STRING) TO ROLE GEMINI_PLUGIN_ROLE;

-- -----------------------------------------------------------------------------
-- 4. Support documents + Cortex Search
--    Demo policy text authored for this plugin (not real Snowflake policy).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SUPPORT_DOCS (
  DOC_NAME STRING,
  TITLE    STRING,
  CONTENT  STRING
);

INSERT INTO SUPPORT_DOCS VALUES
('return_policy.pdf', 'Return Policy',
 'Customers may return any part within 30 days of delivery for a full refund. Items that arrive damaged are eligible for a free replacement or full refund, including return shipping, if reported within 7 days of delivery with a photo of the damage. Open a support ticket with category damaged_item and the order number. A prepaid return label is emailed within 1 business day of ticket creation. Refunds are issued to the original payment method within 5 business days of receiving the returned item.'),
('shipping_faq.pdf', 'Shipping FAQ',
 'Standard shipping takes 5 to 7 business days from the ship date. Expedited shipping takes 2 to 3 business days and priority overnight delivers the next business day. Shipping SLAs by region: AMERICA standard 5 business days; EUROPE standard 6 business days; ASIA standard 7 business days; AFRICA and MIDDLE EAST standard 10 business days. Orders placed before 2 PM local warehouse time ship the same day. Tracking numbers are sent by email when the order ships.'),
('pricing_guide.pdf', 'Pricing Guide',
 'Bulk order discounts apply automatically at checkout: 5 percent off orders of 100 to 499 units, 10 percent off 500 to 999 units, and 15 percent off 1,000 units or more of the same part. Regional discounts: account managers may approve an additional regional discount of up to 5 percent in any region whose revenue declined year over year, to support customer retention. Discounts cannot be combined with promotional pricing. Contract customers receive pricing defined in their supplier agreement.'),
('warranty_terms.pdf', 'Warranty Terms',
 'Parts sourced under supplier contracts carry a 12-month limited warranty from the delivery date covering manufacturing defects. Parts in the LARGE and JUMBO container classes carry an extended 24-month warranty. The warranty does not cover misuse, improper installation, or normal wear. To file a warranty claim, open a support ticket with category other, include the part number and order number, and attach proof of the defect. Approved claims are fulfilled by replacement part.'),
('escalation_process.pdf', 'Escalation Process',
 'Late delivery complaints are handled in tiers. Tier 1 support responds within 4 business hours and checks carrier tracking. If the order is more than 5 business days past its shipping SLA, or the customer is in the AUTOMOBILE or MACHINERY segment with an urgent-priority order, escalate the ticket to tier 2 by setting its status to ESCALATED. Tier 2 contacts the carrier and offers expedited reshipment or a shipping refund within 1 business day. Before contacting a customer about an overdue order, review their open orders, order priority, and any existing open tickets.');

CREATE OR REPLACE CORTEX SEARCH SERVICE SUPPORT_DOCS_SEARCH
  ON CONTENT
  ATTRIBUTES DOC_NAME, TITLE
  WAREHOUSE = GEMINI_WH
  TARGET_LAG = '1 day'
  AS SELECT DOC_NAME, TITLE, CONTENT FROM GEMINI_DEMO.TPCH.SUPPORT_DOCS;

GRANT USAGE ON CORTEX SEARCH SERVICE SUPPORT_DOCS_SEARCH TO ROLE GEMINI_PLUGIN_ROLE;

-- -----------------------------------------------------------------------------
-- 5. Semantic view (Cortex Analyst)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW TPCH_SALES_SV
  TABLES (
    orders   AS GEMINI_DEMO.TPCH.ORDERS   PRIMARY KEY (O_ORDERKEY) COMMENT = 'One row per customer order',
    customer AS GEMINI_DEMO.TPCH.CUSTOMER PRIMARY KEY (C_CUSTKEY)  COMMENT = 'Customers who place orders',
    nation   AS GEMINI_DEMO.TPCH.NATION   PRIMARY KEY (N_NATIONKEY) COMMENT = 'Nations (countries)',
    region   AS GEMINI_DEMO.TPCH.REGION   PRIMARY KEY (R_REGIONKEY) COMMENT = 'World regions'
  )
  RELATIONSHIPS (
    orders_to_customer AS orders (O_CUSTKEY)     REFERENCES customer,
    customer_to_nation AS customer (C_NATIONKEY) REFERENCES nation,
    nation_to_region   AS nation (N_REGIONKEY)   REFERENCES region
  )
  FACTS (
    orders.order_total_price AS O_TOTALPRICE COMMENT = 'Total price of the order in USD',
    customer.account_balance AS C_ACCTBAL    COMMENT = 'Customer account balance in USD'
  )
  DIMENSIONS (
    orders.order_key      AS O_ORDERKEY      COMMENT = 'Order identifier',
    orders.order_date     AS O_ORDERDATE     COMMENT = 'Date the order was placed',
    orders.order_year     AS YEAR(O_ORDERDATE) COMMENT = 'Year the order was placed',
    orders.order_status   AS O_ORDERSTATUS   COMMENT = 'Order status: O = open, F = fulfilled, P = partially shipped',
    orders.order_priority AS O_ORDERPRIORITY COMMENT = 'Order priority: 1-URGENT, 2-HIGH, 3-MEDIUM, 4-NOT SPECIFIED, 5-LOW',
    customer.customer_key  AS C_CUSTKEY     COMMENT = 'Customer number, e.g. customer #1234',
    customer.customer_name AS C_NAME        COMMENT = 'Customer name, e.g. Customer#000001234',
    customer.market_segment AS C_MKTSEGMENT COMMENT = 'Market segment: AUTOMOBILE, BUILDING, FURNITURE, HOUSEHOLD, MACHINERY',
    nation.nation_name    AS N_NAME          COMMENT = 'Customer nation name',
    region.region_name    AS R_NAME          COMMENT = 'Customer region: AFRICA, AMERICA, ASIA, EUROPE, MIDDLE EAST'
  )
  METRICS (
    orders.total_revenue     AS SUM(order_total_price) COMMENT = 'Total order revenue (sum of order total price)',
    orders.order_count       AS COUNT(order_key)       COMMENT = 'Number of orders',
    orders.avg_order_value   AS AVG(order_total_price) COMMENT = 'Average order value',
    customer.customer_count  AS COUNT(customer_key)    COMMENT = 'Number of customers'
  )
  COMMENT = 'TPC-H sales: orders, customers, nations, regions';

GRANT SELECT ON SEMANTIC VIEW TPCH_SALES_SV TO ROLE GEMINI_PLUGIN_ROLE;

-- -----------------------------------------------------------------------------
-- 6. Cortex Agent (orchestrates Analyst + Search)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT TPCH_BUSINESS_AGENT
  COMMENT = 'Answers TPC-H business questions that combine sales data with support policy documents.'
  FROM SPECIFICATION $$
  instructions:
    response: "Answer concisely. Lead with the number or finding, then a short explanation. Cite the policy document name when you use one."
    orchestration: "Use sales_analyst for revenue, orders, customers, segments, nations and regions. Use support_docs for return, shipping, pricing, discount, warranty and escalation policy. Use both when a question mixes data and policy."
  tools:
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: sales_analyst
        description: "TPC-H sales data: orders, revenue, customers, market segments, nations, regions."
    - tool_spec:
        type: cortex_search
        name: support_docs
        description: "Support policy documents: return policy, shipping FAQ and SLAs, pricing and discounts, warranty terms, escalation process."
  tool_resources:
    sales_analyst:
      semantic_view: GEMINI_DEMO.TPCH.TPCH_SALES_SV
      execution_environment:
        type: warehouse
        warehouse: GEMINI_WH
    support_docs:
      name: GEMINI_DEMO.TPCH.SUPPORT_DOCS_SEARCH
      max_results: 3
      title_column: TITLE
      id_column: DOC_NAME
  $$;

GRANT USAGE ON AGENT TPCH_BUSINESS_AGENT TO ROLE GEMINI_PLUGIN_ROLE;

-- -----------------------------------------------------------------------------
-- 7. MCP server (grants are dropped on replace, so they follow immediately)
--    No SYSTEM_EXECUTE_SQL tool: Snowflake recommends against exposing raw SQL
--    next to a governed agent, and its read-only hint can't be overridden.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE MCP SERVER GEMINI_DEMO.TPCH.GEMINI_PLUGIN_MCP
  FROM SPECIFICATION $$
  tools:
    - name: "tpch_sales_analyst"
      title: "TPC-H Sales Analyst"
      type: "CORTEX_ANALYST_MESSAGE"
      identifier: "GEMINI_DEMO.TPCH.TPCH_SALES_SV"
      description: "Answers natural-language questions about TPC-H orders, revenue, customers, market segments, nations and regions by generating SQL over a governed semantic view."
    - name: "support_docs_search"
      title: "Support Docs Search"
      type: "CORTEX_SEARCH_SERVICE_QUERY"
      identifier: "GEMINI_DEMO.TPCH.SUPPORT_DOCS_SEARCH"
      description: "Searches support policy documents: returns, shipping times and SLAs, pricing and bulk discounts, warranty terms, escalation process."
    - name: "tpch_business_agent"
      title: "TPC-H Business Agent"
      type: "CORTEX_AGENT_RUN"
      identifier: "GEMINI_DEMO.TPCH.TPCH_BUSINESS_AGENT"
      description: "Answers multi-step business questions that combine TPC-H sales data with support policy documents."
      annotations:
        readOnlyHint: true
        destructiveHint: false
        openWorldHint: false
    - name: "create_support_ticket"
      title: "Create Support Ticket"
      type: "GENERIC"
      identifier: "GEMINI_DEMO.TPCH.CREATE_SUPPORT_TICKET"
      description: "Creates a support ticket for an existing customer. Returns the new ticket_id."
      annotations:
        readOnlyHint: false
        destructiveHint: false
        idempotentHint: false
        openWorldHint: false
      config:
        type: "procedure"
        warehouse: "GEMINI_WH"
        query_timeout: 60
        input_schema:
          type: "object"
          properties:
            customer_key:
              type: "number"
              description: "Customer number, e.g. 1234"
            category:
              type: "string"
              description: "One of: damaged_item, late_delivery, billing, return, wrong_item, other"
            description:
              type: "string"
              description: "Short description of the issue"
            priority:
              type: "string"
              description: "One of: low, medium, high, critical. Default medium"
          required: ["customer_key", "category", "description"]
    - name: "update_ticket_status"
      title: "Update Ticket Status"
      type: "GENERIC"
      identifier: "GEMINI_DEMO.TPCH.UPDATE_TICKET_STATUS"
      description: "Changes the status of an existing support ticket, with an optional reason."
      annotations:
        readOnlyHint: false
        destructiveHint: false
        idempotentHint: true
        openWorldHint: false
      config:
        type: "procedure"
        warehouse: "GEMINI_WH"
        query_timeout: 60
        input_schema:
          type: "object"
          properties:
            ticket_id:
              type: "string"
              description: "Ticket ID, e.g. T-1001"
            status:
              type: "string"
              description: "One of: OPEN, ON_HOLD, ESCALATED, RESOLVED, CLOSED"
            reason:
              type: "string"
              description: "Optional reason, e.g. duplicate"
          required: ["ticket_id", "status"]
  $$;

GRANT USAGE ON MCP SERVER GEMINI_DEMO.TPCH.GEMINI_PLUGIN_MCP TO ROLE GEMINI_PLUGIN_ROLE;

-- -----------------------------------------------------------------------------
-- 8. OAuth integration for Gemini (3-legged, confidential client)
-- -----------------------------------------------------------------------------
CREATE SECURITY INTEGRATION IF NOT EXISTS GEMINI_PLUGIN_OAUTH
  TYPE = OAUTH
  OAUTH_CLIENT = CUSTOM
  OAUTH_CLIENT_TYPE = 'CONFIDENTIAL'
  OAUTH_REDIRECT_URI = 'https://vertexaisearch.cloud.google.com/oauth-redirect'
  OAUTH_USE_SECONDARY_ROLES = NONE
  OAUTH_ISSUE_REFRESH_TOKENS = TRUE
  ALLOWED_ROLES_LIST = ('GEMINI_PLUGIN_ROLE')
  ENABLED = TRUE;

-- Client ID/secret for Gemini: run manually, share through a secure channel, never commit.
-- SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('GEMINI_PLUGIN_OAUTH');

-- -----------------------------------------------------------------------------
-- 9. Tester users (Google Gemini Factory)
--    Passwords are set separately with a random value and shared privately.
--    The user-level network policy lets testers and Gemini's OAuth calls through
--    without changing the account network policy.
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS SUNNYWALIA LOGIN_NAME = 'sunnywalia@google.com' EMAIL = 'sunnywalia@google.com'
  DISPLAY_NAME = 'Sunny Walia (Google)' TYPE = PERSON
  DEFAULT_ROLE = GEMINI_PLUGIN_ROLE DEFAULT_WAREHOUSE = GEMINI_WH MUST_CHANGE_PASSWORD = TRUE;
CREATE USER IF NOT EXISTS UNNAYANJAIN LOGIN_NAME = 'unnayanjain@google.com' EMAIL = 'unnayanjain@google.com'
  DISPLAY_NAME = 'Unnayan Jain (Google)' TYPE = PERSON
  DEFAULT_ROLE = GEMINI_PLUGIN_ROLE DEFAULT_WAREHOUSE = GEMINI_WH MUST_CHANGE_PASSWORD = TRUE;
GRANT ROLE GEMINI_PLUGIN_ROLE TO USER SUNNYWALIA;
GRANT ROLE GEMINI_PLUGIN_ROLE TO USER UNNAYANJAIN;

CREATE NETWORK RULE IF NOT EXISTS GEMINI_DEMO.TPCH.GEMINI_TESTERS_ALLOW_ALL
  MODE = INGRESS TYPE = IPV4 VALUE_LIST = ('0.0.0.0/0') COMMENT = 'Google Gemini tester users only';
CREATE NETWORK POLICY IF NOT EXISTS GEMINI_TESTERS_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('GEMINI_DEMO.TPCH.GEMINI_TESTERS_ALLOW_ALL')
  COMMENT = 'Applied only to Google Gemini tester users';
ALTER USER SUNNYWALIA  SET NETWORK_POLICY = GEMINI_TESTERS_POLICY;
ALTER USER UNNAYANJAIN SET NETWORK_POLICY = GEMINI_TESTERS_POLICY;
