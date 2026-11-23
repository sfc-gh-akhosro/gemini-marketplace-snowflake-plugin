# Snowflake Plugin for Gemini Agent

Snowflake's launch-partner plugin for the Gemini Agent plugin marketplace (target launch: December 2026). It lets Gemini Agent users query, search, and update governed Snowflake data through a Snowflake-managed remote MCP server secured with OAuth.

## What we're building

| Piece | Where | What it does |
| --- | --- | --- |
| Plugin manifest | `.gemini-plugin/plugin.json` | Name, version, author, and the skill list, plus a pointer to `.mcp.json` |
| MCP config | `.mcp.json` | HTTPS endpoint of the Snowflake-managed MCP server (OAuth 2.0) |
| Skills | `skills/snowflake-*/SKILL.md` | Step-by-step instructions telling Gemini which MCP tool to call and when |
| Snowflake backend | `snowflake/setup.sql` | Demo data (`GEMINI_DEMO.TPCH`), semantic view, Cortex Search, Cortex Agent, write procedures, MCP server, OAuth integration |
| Golden dataset | Google Sheet (shared with Google) | 20–30 test prompts with expected answers |

### Skills and MCP tools

| Skill | MCP tool | Backed by | Mode |
| --- | --- | --- | --- |
| `snowflake-query-data` | `tpch_sales_analyst` | Cortex Agent `TPCH_SALES_AGENT` (Analyst on semantic view `TPCH_SALES_SV`) | Read |
| `snowflake-search-documents` | `support_docs_search` | Cortex Search service `SUPPORT_DOCS_SEARCH` | Read |
| `snowflake-ask-agent` | `tpch_business_agent` | Cortex Agent `TPCH_BUSINESS_AGENT` | Read |
| `snowflake-manage-records` | `create_support_ticket`, `update_ticket_status` | Stored procedures | Write |

There is deliberately no raw SQL tool. Snowflake recommends against exposing `SYSTEM_EXECUTE_SQL` next to a governed agent, because it bypasses the semantic view.

## Sources and guides

- **Google: Partner Plugin & Skill Best Practices Guide (v3)**: package layout, `SKILL.md` rules, MCP hygiene, the 26 security checks (CRIT-01 to CRIT-26). https://services.google.com/fh/files/misc/gemini-partner-plugin-best-practices-guide-v3.pdf
- **Google: Golden Evaluation Dataset Template (v3)**: two tabs, *Search and Answers* and *Mutative Actions*. https://services.google.com/fh/files/misc/gemini-partner-plugin-golden-evaluation-dataset-template-v3.pdf
- **Snowflake quickstart (ours): Snowflake Cortex + Gemini Enterprise on Iceberg**: MCP server, OAuth integration, and the Gemini connector pattern. https://www.snowflake.com/en/developers/guides/quickstart-iceberg-cortex-gemini/
- **Snowflake docs**: [MCP servers](https://docs.snowflake.com/en/user-guide/snowflake-cortex/mcp-server), [Cortex Agents](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents), [Semantic views](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/semantic-view)

## Google's asks (email thread with Gemini Factory, Nov 2026)

- [x] Form 1 (Onboarding) and Form 2 (Pre-GA Terms) submitted
- [x] Plugin package in this repo: `plugin.json`, `.mcp.json`, `LICENSE`, and 4 skills (Markdown only); the raw SQL skill was dropped
- [ ] MCP access with read and write permissions for the testers `sunnywalia@google.com` and `unnayanjain@google.com`
- [x] Golden dataset: real expected answers from `GEMINI_DEMO.TPCH`, rows 6 and 19 fixed, SQL rows replaced with Analyst rows

## Key packaging rules (from the guide)

- Manifest only inside `.gemini-plugin/`; `skills/` and `.mcp.json` sit at the repo root
- `name` slugs use kebab-case with a `snowflake-` prefix; never use bare Google product names
- `SKILL.md`: description at most 1,024 characters, with trigger phrases and "Don't use for…" boundaries; body of 150–300 lines (hard cap 500); no CLI installs
- No secrets anywhere in the package (CRIT-21)
- Read tools must return `readOnlyHint: true`
- OAuth redirect URI: `https://vertexaisearch.cloud.google.com/oauth-redirect`
- Pin the git commit SHA or release tag when submitting

## Setup (for testers)

1. A Snowflake admin runs `snowflake/setup.sql` (creates the data, the MCP server, and the OAuth integration).
2. In Gemini Agent, install the plugin from this repo and sign in to Snowflake through OAuth.
3. Required Snowflake role: `GEMINI_PLUGIN_ROLE`, set as the user's default role, with `GEMINI_WH` as the default warehouse. The role can read `GEMINI_DEMO.TPCH` and write tickets only through the two procedures.
4. Before each evaluation pass, an admin runs `CALL GEMINI_DEMO.TPCH.RESET_DEMO_TICKETS();` so tickets T-1001 to T-1005 match the golden dataset preconditions.
