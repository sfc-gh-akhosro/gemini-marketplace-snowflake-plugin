---
name: snowflake-query-data
description: Answers quantitative questions about Snowflake TPC-H sales data (orders, revenue, average order value, customers, market segments, nations, regions, order status and priority) by calling the tpch_sales_analyst tool, which generates governed SQL over the TPCH_SALES_SV semantic view. Use when the user asks to "count orders", "show revenue by region", "which segment earns the most", "top customers by spend", "how many open orders", or any single metric, ranking, or breakdown over the sales data. Don't use for policy or documentation questions (use snowflake-search-documents), questions that combine data with policy or need a narrative across several steps (use snowflake-ask-agent), or creating and updating support tickets (use snowflake-manage-records).
---

# Snowflake Query Data

Answer data questions about the TPC-H sales dataset in Snowflake. Every answer must come from
the `tpch_sales_analyst` tool. Never estimate or invent numbers.

## Available MCP Tools

| Tool Name | Mode | Purpose & Required Inputs |
| :--- | :--- | :--- |
| `tpch_sales_analyst` | Read (`readOnlyHint: true`) | Converts a natural-language question into SQL over the `GEMINI_DEMO.TPCH.TPCH_SALES_SV` semantic view, runs it, and returns the SQL plus results. Input: `message` (the question as text). |

## What the Data Covers

The semantic view joins four tables: orders, customer, nation, region.

| Concept | Meaning |
| :--- | :--- |
| Total revenue | Sum of order total price, in USD |
| Order count | Number of orders |
| Average order value | Average order total price |
| Customer count | Number of customers |
| Order date / year | When the order was placed (data spans 1992-01-01 to 1998-08-02) |
| Order status | `O` = open, `F` = fulfilled, `P` = partially shipped |
| Order priority | `1-URGENT`, `2-HIGH`, `3-MEDIUM`, `4-NOT SPECIFIED`, `5-LOW` |
| Market segment | `AUTOMOBILE`, `BUILDING`, `FURNITURE`, `HOUSEHOLD`, `MACHINERY` |
| Region | `AFRICA`, `AMERICA`, `ASIA`, `EUROPE`, `MIDDLE EAST` |
| Nation | 25 nations, each in one region |
| Customer | Customer number (for example `1234`) and name (for example `Customer#000001234`) |

The view does not cover suppliers, parts, line items, or support tickets.

## Standard Execution Workflow

1. **Prerequisite & Scope Check**
   - Confirm the question is about the concepts in the table above.
   - If it asks about suppliers, parts, or line items, tell the user the sales view does not
     include that data instead of guessing.
   - If it also asks about policy (returns, shipping, discounts, warranty, escalation), switch
     to `snowflake-ask-agent`.

2. **Execute Scoped Read Query**
   - Call `tpch_sales_analyst` once, with the user's question as `message`.
   - Rewrite the question only to make it explicit:
     - Resolve relative years against the data range. "Last year in the data" means 1998,
       which is partial and ends in August.
     - Spell out codes. "Open orders" means order status `O`; "urgent" means priority `1-URGENT`.
     - Keep rankings bounded. Ask for the top 5 or top 10 instead of every row.
   - Do not split one question into many calls unless the first answer is missing a piece the
     user asked for.

3. **Validate the Result**
   - Check that the returned SQL filters and groups the way the user asked (year, segment,
     region, status).
   - If the tool returns a clarification request, or the SQL clearly answers a different
     question, ask the user one short clarifying question. Do not retry blindly.
   - If the result is empty, say so and suggest the nearest valid filter (for example, a year
     inside 1992-1998).

4. **Present the Answer**
   - Lead with the number or ranking in one sentence.
   - Format currency with a `$` sign and thousands separators. Use billions (B) or millions (M)
     for large totals, and give the exact value when the user asks for one number.
   - For rankings, use a short list or a small table.
   - Mention the 1998 partial-year caveat whenever 1998 appears in a trend.
   - Offer the generated SQL if the user wants to see how the number was computed.

## Examples

| User asks | Call | Answer shape |
| :--- | :--- | :--- |
| "How many orders are in the dataset?" | `tpch_sales_analyst` with that question | "There are 1,500,000 orders." |
| "Which market segment generates the most revenue?" | `tpch_sales_analyst` | Segment name plus revenue, with the runner-up |
| "Show revenue by region for 1997, highest first" | `tpch_sales_analyst` | 5 regions in descending order |
| "Top 5 customers by total spend" | `tpch_sales_analyst` | 5 customer names with spend |

## Error Handling

- **Permission or authorization error:** the user's Snowflake role lacks access to the
  semantic view. Tell the user to ask their Snowflake admin for the `GEMINI_PLUGIN_ROLE` role.
- **Timeout:** narrow the question (one year, one region, or the top 10) and call once more.
- **Tool not found:** the MCP connection is not active. Ask the user to reconnect the
  Snowflake plugin and sign in again.
