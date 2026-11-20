---
name: snowflake-manage-records
description: Creates and updates customer support tickets stored in Snowflake by calling the create_support_ticket and update_ticket_status tools, which run validated stored procedures against the GEMINI_DEMO.TPCH.SUPPORT_TICKETS table. Use when the user asks to "log a support ticket", "open a high-priority ticket for customer #5678", "file a ticket about a return label", "mark ticket T-1001 as resolved", "escalate a ticket to tier 2", "reopen a ticket", "put a ticket on hold", or "close a ticket as a duplicate". Don't use for questions about sales numbers (use snowflake-query-data), policy lookups (use snowflake-search-documents), or analysis that combines data and policy (use snowflake-ask-agent).
---

# Snowflake Manage Records

Create and update support tickets in Snowflake. These are write actions. Confirm the inputs,
then call the tool once, then report exactly what changed.

## Available MCP Tools

| Tool Name | Mode | Purpose & Required Inputs |
| :--- | :--- | :--- |
| `create_support_ticket` | Write (`readOnlyHint: false`) | Creates a ticket with status `OPEN`. Required: `customer_key` (number), `category`, `description`. Optional: `priority` (default `medium`). Returns the new `ticket_id`. |
| `update_ticket_status` | Write (`readOnlyHint: false`) | Changes the status of an existing ticket. Required: `ticket_id`, `status`. Optional: `reason`. Returns `previous_status` and `status`. |

## Allowed Values

| Field | Values |
| :--- | :--- |
| `category` | `damaged_item`, `late_delivery`, `billing`, `return`, `wrong_item`, `other` |
| `priority` | `low`, `medium`, `high`, `critical` |
| `status` | `OPEN`, `ON_HOLD`, `ESCALATED`, `RESOLVED`, `CLOSED` |
| `ticket_id` | Format `T-` followed by a number, for example `T-1001` |
| `customer_key` | The customer number, for example `1234` for "customer #1234" |

## Mapping User Language to Values

| User says | Use |
| :--- | :--- |
| "arrived damaged", "broken" | `category: damaged_item` |
| "late", "hasn't arrived" | `category: late_delivery` |
| "invoice", "charge", "billing question" | `category: billing` |
| "return label", "send it back" | `category: return` |
| "wrong part", "wrong item" | `category: wrong_item` |
| "high-priority", "urgent" | `priority: high` |
| "resolved", "fixed" | `status: RESOLVED` |
| "escalate", "tier 2" | `status: ESCALATED` |
| "reopen" | `status: OPEN` |
| "on hold", "waiting for the customer" | `status: ON_HOLD` |
| "close", "duplicate" | `status: CLOSED` (put "duplicate" in `reason`) |

## Standard Execution Workflow

1. **Prerequisite & ID Resolution**
   - Extract the customer number or the ticket ID from the user's request. Never guess an ID.
   - Map the user's wording to the allowed values using the tables above.

2. **Preflight Validation Before Mutating**
   - For `create_support_ticket`, confirm that `customer_key`, `category` and `description`
     are all known. Write `description` as a short phrase in the user's words, for example
     "Order arrived damaged".
   - For `update_ticket_status`, confirm that `ticket_id` and `status` are known.
   - If any required field is missing or ambiguous, ask the user one question before calling.
   - If the request is clear and complete, proceed without extra confirmation. Gemini shows
     its own approval prompt for write tools.

3. **Execute the Write Once**
   - Call the tool exactly once with the validated arguments.
   - Do not retry automatically after an error. A retry of `create_support_ticket` could
     create a duplicate ticket.

4. **Post-Action Verification**
   - Read the returned object.
     - On success, `create_support_ticket` returns `ticket_id`, `customer_key`, `category`,
       `priority` and `status`; `update_ticket_status` returns `ticket_id`,
       `previous_status` and `status`.
     - On failure, the result contains an `error` field (for example "Customer 99999999 not
       found" or "Ticket T-9999 not found").
   - On success, confirm in one sentence, for example:
     "Created ticket T-1006 for customer 1234 (damaged_item, medium priority, OPEN)."
     or "Ticket T-1001 changed from OPEN to RESOLVED."
   - On error, show the message and ask the user how to correct it.

## Examples

| User asks | Tool | Arguments |
| :--- | :--- | :--- |
| "Log a support ticket for customer #1234: order arrived damaged" | `create_support_ticket` | `{"customer_key": 1234, "category": "damaged_item", "description": "Order arrived damaged"}` |
| "Open a high-priority ticket for customer #5678 about a late delivery" | `create_support_ticket` | `{"customer_key": 5678, "category": "late_delivery", "priority": "high", "description": "Late delivery"}` |
| "Escalate ticket T-1002 to tier 2" | `update_ticket_status` | `{"ticket_id": "T-1002", "status": "ESCALATED"}` |
| "Close ticket T-1005 as a duplicate" | `update_ticket_status` | `{"ticket_id": "T-1005", "status": "CLOSED", "reason": "duplicate"}` |

## Error Handling

- **Permission error:** the user's role lacks `USAGE` on the procedure. Tell the user to ask
  their Snowflake admin for `GEMINI_PLUGIN_ROLE`.
- **Invalid value error:** the tool lists the allowed values. Map the user's intent to one of
  them, or ask the user which they meant.
- **Not found error:** confirm the customer number or ticket ID with the user.
