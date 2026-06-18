# CLAUDE.md — Iron Forge

Context for any AI assistant (or engineer) working in this repository. Read this first.

## What this is

Iron Forge is an AI-powered revenue-recovery system for service businesses: it re-engages
missed calls, dead quotes, and unpaid invoices over SMS using Claude, recovering revenue the
business would otherwise lose. One architecture serves every vertical; only the trigger source,
system prompt, and objection library change between them.

This repo is a clean, self-hostable **reference rebuild** of the production stack (the original
deployment infrastructure was on a VPS that has since been torn down). Treat the code here as
the source of truth.

## Stack

- **n8n** (self-hosted, Docker) — workflow orchestration. Logic lives in Code nodes.
- **Claude** (Anthropic Messages API) — conversation generation. Model id comes from
  `$env.CLAUDE_MODEL`, default `claude-sonnet-4-6`. See "Model discipline" below.
- **Supabase** (Postgres + Realtime + RLS) — application database. Schema in `db/`.
- **Twilio** (SMS, 10DLC) · **Stripe** (payments) · **Caddy** (TLS/reverse proxy).

## The seven-stage pipeline (every vertical)

1. Trigger ingestion → `code_nodes/validate_payload.js`
2. Context enrichment → `code_nodes/build_context.js`
3. AI generation → `code_nodes/claude_generate.js`
4. Compliance gate → `code_nodes/compliance_gate.js`
5. SMS delivery (Twilio)
6. Inbound response handling → `prompts/intent_classifier.md`
7. Outcome logging (Supabase → `vertical_intelligence`)

## Conventions & guardrails (do not break these)

- **Never hardcode secrets.** Everything sensitive is read from the environment
  (`$env.ANTHROPIC_API_KEY`, `$env.SUPABASE_SERVICE_ROLE_KEY`, etc.). `.env` is gitignored;
  `.env.example` uses `[REDACTED]` placeholders.
- **Compliance is enforced in code, never delegated to the model.** TCPA quiet hours, opt-out,
  frequency caps, and HIPAA PHI filtering all live in `compliance_gate.js` and run before any
  send. Nothing sends unless `compliance_passed === true`. Every send/block logs its
  `compliance_flags`.
- **The model's output is constrained by a schema.** `claude_generate.js` uses
  `output_config.format` (json_schema, `additionalProperties:false`). The model returns only
  `sms_text`, `detected_objection_category`, `resolution_strategy`, `sentiment`,
  `requires_human_escalation`. Do not loosen this — it's the metadata-leak guard.
- **The structured outcome log is the data moat.** Always write objection/strategy/outcome on
  the message + conversation rows; the nightly aggregation depends on it.
- **`code_nodes/*.js` are the canonical source.** The workflow JSON nodes reference them by
  name; if you change logic, change the file in `code_nodes/` and re-paste into the node.

## Model discipline

- `claude-sonnet-4-6` is the production default for per-message SMS generation — current
  Sonnet, chosen for cost and latency at volume (this protects gross margin). Structured
  outputs are supported on it.
- For a vertical that needs deeper reasoning, override `CLAUDE_MODEL` to `claude-opus-4-8`.
- **Do not use a date-suffixed or legacy model id.** Note `db/01_schema.sql` still has
  `model_used DEFAULT 'claude-sonnet-4-20250514'` (deprecated, retires 2026-06-15) — the code
  writes the live model id into the column at insert time; update the column default when
  convenient.

## Running

Local demo: `docker compose up -d n8n-db n8n` → http://localhost:5678. Run `db/01_schema.sql`
then `db/02_intelligence_functions.sql` in your Supabase project. Import the `workflows/` and
paste in the `code_nodes/`. See `README.md` for the curl that fires a test trigger.

Production: set `N8N_DOMAIN`, point DNS at the host, `docker compose up -d` (Caddy auto-TLS).

## When extending

The roadmap that raises this from a strong pipeline to a frontier system: pgvector retrieval
over each client's objection corpus, a true plan-and-execute agent (tool use) in place of the
linear pipeline, and an eval harness (LLM-as-judge over a labeled set) in CI. See
`ARCHITECTURE.md` → roadmap.
