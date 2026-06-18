# CLAUDE.md

Context for an AI assistant (or a new engineer) working in this repo. Read first.

## What this is

Iron Forge re-engages missed calls, dead quotes, and unpaid invoices over SMS using Claude, to
recover revenue a service business would otherwise lose. One pipeline serves every vertical; only
the trigger source, system prompt, and objection list change between them.

This repo is a clean rebuild of the stack that ran in pilot (the original VPS is gone). The code
here is the source of truth.

## Stack

- n8n (self-hosted, Docker) for orchestration. Logic lives in Code nodes.
- Claude (Messages API) for generation. Model from `$env.CLAUDE_MODEL`, default `claude-sonnet-4-6`.
- Supabase (Postgres, Realtime, RLS) for the app database. Schema in `db/`.
- Twilio (SMS, 10DLC), Stripe (payments), Caddy (TLS/reverse proxy).

## Pipeline

1. Trigger ingestion -> `code_nodes/validate_payload.js`
2. Context enrichment -> `code_nodes/build_context.js`
3. Generation -> `code_nodes/claude_generate.js`
4. Compliance gate -> `code_nodes/compliance_gate.js`
5. Delivery (Twilio)
6. Inbound handling -> `prompts/intent_classifier.md`
7. Outcome logging (Supabase -> `vertical_intelligence`)

## Rules that matter

- Never hardcode secrets. Read from env (`$env.ANTHROPIC_API_KEY`, `$env.SUPABASE_SERVICE_ROLE_KEY`).
  `.env` is gitignored; `.env.example` uses `[REDACTED]` placeholders.
- Compliance runs in code, never delegated to the model. Nothing sends unless `compliance_passed`.
  Every send and block logs its flags.
- The model's output is schema-constrained. `claude_generate.js` uses `output_config.format` with
  `additionalProperties:false`. Don't loosen it; that's what keeps preamble and reasoning out of the
  SMS body.
- `code_nodes/*.js` are canonical. The workflow JSON references them by name. Change logic in the file,
  then re-paste into the node.

## Model

- `claude-sonnet-4-6` is the default for per-message generation: cheap and fast at volume. Structured
  outputs are supported on it. Override `CLAUDE_MODEL` to `claude-opus-4-8` for a vertical that needs
  deeper reasoning.
- Don't use a legacy or date-suffixed model id. Note `db/01_schema.sql` still defaults `model_used` to
  `claude-sonnet-4-20250514` (deprecated, retires 2026-06-15). The code writes the live id at insert
  time; update the column default when convenient.

## Running

Local: `docker compose up -d n8n-db n8n`, open http://localhost:5678. Run `db/01_schema.sql` then
`db/02_intelligence_functions.sql` in Supabase. Import `workflows/`, paste in `code_nodes/`. See README
for the test curl. Production: set `N8N_DOMAIN`, point DNS at the host, `docker compose up -d`.

## Extending

Roadmap is in ARCHITECTURE.md: pgvector retrieval, a plan-and-execute agent, an eval harness in CI, a
real PHI classifier.
