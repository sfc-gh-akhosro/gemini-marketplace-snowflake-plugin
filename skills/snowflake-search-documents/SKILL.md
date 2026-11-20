---
name: snowflake-search-documents
description: Finds and quotes answers from Snowflake-hosted support policy documents (return policy, shipping FAQ and regional delivery SLAs, pricing guide and bulk or regional discounts, warranty terms, escalation process) by calling the support_docs_search tool, a Cortex Search service. Use when the user asks "what is the return policy", "how long does shipping take", "find documentation about discounts", "what warranty applies", "how do I escalate a complaint", or wants a policy cited with its source document. Don't use for numbers, counts, or rankings from sales data (use snowflake-query-data), questions that combine policy with sales data (use snowflake-ask-agent), or creating and updating support tickets (use snowflake-manage-records).
---

# Snowflake Search Documents

Answer policy and how-to questions from the support documents indexed in Snowflake Cortex
Search. Ground every statement in a returned document and name that document.

## Available MCP Tools

| Tool Name | Mode | Purpose & Required Inputs |
| :--- | :--- | :--- |
| `support_docs_search` | Read (`readOnlyHint: true`) | Semantic search over `GEMINI_DEMO.TPCH.SUPPORT_DOCS_SEARCH`. Inputs: `query` (required, text), `columns` (optional array, for example `["DOC_NAME", "TITLE", "CONTENT"]`), `limit` (optional, 1-10). |

## Indexed Documents

| Document | Title | Covers |
| :--- | :--- | :--- |
| `return_policy.pdf` | Return Policy | 30-day returns, damaged items, return labels, refund timing |
| `shipping_faq.pdf` | Shipping FAQ | Standard, expedited and overnight times; SLA by region; cut-off times |
| `pricing_guide.pdf` | Pricing Guide | Bulk discount tiers, regional discounts, contract pricing |
| `warranty_terms.pdf` | Warranty Terms | Supplier-contract warranty, container-class extensions, claims |
| `escalation_process.pdf` | Escalation Process | Tier 1 and tier 2 handling, when to escalate, pre-contact checks |

Each result returns `DOC_NAME`, `TITLE`, and `CONTENT`.

## Standard Execution Workflow

1. **Prerequisite & Intent Check**
   - Confirm the user wants policy, process, or documentation, not a number from sales data.
   - If the question mixes both (for example "which region dropped and what discount applies"),
     switch to `snowflake-ask-agent`.

2. **Execute Scoped Search**
   - Call `support_docs_search` with a short, keyword-rich `query` built from the user's words.
     - Example: "How long does standard shipping take?" becomes
       `query: "standard shipping delivery time"`.
   - Set `columns: ["DOC_NAME", "TITLE", "CONTENT"]` and `limit: 3`.
   - Use one call per distinct topic. If the user asks about two topics, make two calls.

3. **Validate Relevance**
   - Read the returned `CONTENT` and keep only passages that actually answer the question.
   - If no result answers it, say the documents do not cover it. Do not fill the gap from
     general knowledge.
   - If two documents conflict, show both and name each source.

4. **Present the Answer**
   - Answer in one to three sentences using the document's own figures (days, percentages,
     tiers).
   - End with the source, for example: "Source: Shipping FAQ (shipping_faq.pdf)."
   - If the policy says to open or escalate a ticket, offer to do it with
     `snowflake-manage-records`. Do not do it unless the user asks.

## Examples

| User asks | Search query | Expected source |
| :--- | :--- | :--- |
| "What is our return policy for damaged items?" | `damaged item return refund` | `return_policy.pdf` |
| "Find documentation about bulk order discounts" | `bulk order discount tiers` | `pricing_guide.pdf` |
| "What warranty applies to parts from supplier contracts?" | `supplier contract parts warranty` | `warranty_terms.pdf` |
| "How do I escalate a late delivery complaint?" | `escalate late delivery complaint tier 2` | `escalation_process.pdf` |

## Error Handling

- **Permission error:** the user's role lacks `USAGE` on the search service. Tell the user to
  ask their Snowflake admin for `GEMINI_PLUGIN_ROLE`.
- **Empty results:** retry once with broader keywords (drop qualifiers such as region or
  tier), then report that nothing matched.
- **Tool not found:** ask the user to reconnect the Snowflake plugin and sign in again.
