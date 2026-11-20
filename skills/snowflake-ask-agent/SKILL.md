---
name: snowflake-ask-agent
description: Answers multi-step business questions that combine Snowflake TPC-H sales data with support policy documents by calling the tpch_business_agent tool, a Snowflake Cortex Agent that orchestrates the sales semantic view and the policy search service. Use when the user asks to "summarize sales performance", "explain a trend and why it matters", "which region dropped and what does policy say", "top nations and their shipping SLA", "what should I know before contacting a customer", or any question needing both numbers and policy, or a narrative across several steps. Don't use for a single metric or ranking (use snowflake-query-data), a plain policy lookup (use snowflake-search-documents), or creating and updating support tickets (use snowflake-manage-records).
---

# Snowflake Ask Agent

Delegate multi-step questions to a governed Snowflake Cortex Agent. The agent decides when to
query sales data and when to search policy documents, then returns one grounded answer.

## Available MCP Tools

| Tool Name | Mode | Purpose & Required Inputs |
| :--- | :--- | :--- |
| `tpch_business_agent` | Read (`readOnlyHint: true`) | Runs the Cortex Agent `GEMINI_DEMO.TPCH.TPCH_BUSINESS_AGENT`. Inputs: `text` (required, the question). For a follow-up, also pass `thread_id` and `parent_message_id` from the previous result. Optional: `background: true` for long runs. |
| `ASYNC_AGENT_RUN_STATUS` | Read | Added automatically by Snowflake. Checks a background run. Input: `run_id`. |
| `AGENT_RUN_RESULT` | Read | Added automatically by Snowflake. Fetches a finished run. Input: `run_id`. |

## What the Agent Can Reach

- **Sales data** (semantic view `TPCH_SALES_SV`): orders, revenue, customers, market segments,
  nations, regions, order status and priority, from 1992 to August 1998.
- **Policy documents** (search service `SUPPORT_DOCS_SEARCH`): return policy, shipping FAQ and
  regional SLAs, pricing guide, warranty terms, escalation process.

It cannot create or change tickets. It reads only.

## Standard Execution Workflow

1. **Prerequisite & Routing Check**
   - Confirm the question needs both data and policy, or several analysis steps.
   - If it is a single number or ranking, use `snowflake-query-data` instead.
   - If it is a single policy lookup, use `snowflake-search-documents` instead.
   - Resolve identifiers the user gave in shorthand. "Customer #1234" is customer key `1234`.

2. **Execute the Agent Run**
   - Call `tpch_business_agent` with `text` set to the user's question, keeping every detail
     (years, segments, regions, customer numbers).
   - For a follow-up in the same conversation, pass the `thread_id` and `parent_message_id`
     returned by the previous call, so the agent keeps its context.
   - If the question is broad (for example a full multi-year story), set `background: true`,
     then poll `ASYNC_AGENT_RUN_STATUS` with the returned `run_id` until it reports
     `completed`, and read the answer with `AGENT_RUN_RESULT`.

3. **Validate the Response**
   - Check that each number in the answer comes from the agent's returned results, and that
     each policy claim names a document.
   - If the agent asks a clarifying question, pass it to the user unchanged and wait.
   - If part of the question was not answered, call once more with only the missing part.

4. **Present the Answer**
   - Lead with the finding, then give the supporting numbers, then the policy implication.
   - Name the policy document for every policy statement, for example
     "per the Pricing Guide (pricing_guide.pdf)".
   - Note that 1998 data is partial (ends August 1998) when a trend includes 1998.
   - If the answer suggests an action (escalate, open a ticket), offer it through
     `snowflake-manage-records`. Do not take it unless the user agrees.

## Examples

| User asks | Agent combines |
| :--- | :--- |
| "Which region had the biggest revenue drop from 1996 to 1997, and what does policy say about regional discounts?" | Revenue by region and year, plus the regional discount rule in `pricing_guide.pdf` |
| "Give me the top 3 nations by customer count and the shipping SLA for each" | Customer count by nation, plus regional SLAs in `shipping_faq.pdf` |
| "What should I know before contacting customer #1234 about an overdue order?" | That customer's orders, open orders and priorities, plus the pre-contact checks in `escalation_process.pdf` |
| "Are urgent orders growing year over year? Explain why it matters" | Urgent order count by year, plus a short interpretation |

## Error Handling

- **Permission error:** the user's role lacks `USAGE` on the agent, the semantic view, or the
  search service. Tell the user to ask their Snowflake admin for `GEMINI_PLUGIN_ROLE`.
- **Timeout:** retry once with `background: true` and poll for the result.
- **Run status `failed`:** report the error message and offer a narrower question.
