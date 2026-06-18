# Iron Forge — Architecture

This document covers the design and the trade-offs behind them. It is written to be read by
an engineer evaluating the system, not just to run it.

## The core bet: one architecture, swappable verticals

Iron Forge deploys revenue recovery for a new business vertical without a re-architecture.
The same seven-stage pipeline runs for roofing dead-quotes and dental unpaid-invoices alike;
the only things that change are:

1. **Trigger source** — which CRM/PMS/AMS event starts the conversation.
2. **System prompt** — the vertical's voice and selling logic (`prompts/`).
3. **Objection library** — the seed rows in `vertical_intelligence` for that vertical.

Everything else — context enrichment, generation, compliance, delivery, logging — is shared
code. That reusability is the central design bet: standing up a new vertical is a
prompt-engineering + data task, not an engineering project.

## Data flow

```
  Client system ──(webhook)──▶  [1] Trigger Ingestion (n8n)
                                     │  validate_payload.js
                                     ▼
                                 Supabase: upsert contact, open conversation
                                     │
                                     ▼
                                 [2] Context Enrichment
                                     │  build_context.js  ← client + history + ranked strategies
                                     ▼
                                 [3] AI Generation
                                     │  claude_generate.js → Anthropic Messages API
                                     │  (structured output: sms_text + metadata only)
                                     ▼
                                 [4] Compliance Gate (deterministic, in code)
                                     │  opt-out · TCPA hours · frequency · HIPAA PHI
                                     ├── fail ─▶ log blocked + escalate to human
                                     ▼ pass
                                 [5] Delivery — Twilio send, capture message SID
                                     ▼
                                 [7] Outcome Logging — structured row to Supabase
                                            │
   contact replies ──(webhook)──▶  [6] Inbound Handler
                                     │  intent_classifier.md → route: payment / schedule / follow-up / human
                                     ▼
                                 (loops back into generation or escalates)
```

## Why these components

**n8n, self-hosted.** The orchestration graph is the product's backbone, so it shouldn't be a
black box billed per operation. Self-hosting on a single VPS keeps per-conversation cost near
zero, which is what makes a performance-based pricing model (a percentage of recovered revenue)
viable at scale. The trade-off is that we own uptime and upgrades — acceptable for a system
whose margin depends on owning the runtime.

**Claude with structured outputs.** Stage 3 calls the Anthropic Messages API with
`output_config.format` and a strict JSON schema (`additionalProperties:false`). This is a
deliberate reliability choice: the model **cannot** return a friendly preamble, a
"here's a draft", or visible reasoning — only the five declared fields. `sms_text` goes to the
carrier; `detected_objection_category` / `resolution_strategy` / `sentiment` are logged to the
data-moat tables; `requires_human_escalation` lets the model hand off cleanly and is treated as
a hard stop by the compliance gate. Model is `claude-sonnet-4-6` — current Sonnet is the right
tier for high-volume per-message generation (cost and latency), and is swappable per vertical
via `CLAUDE_MODEL` for cases that need deeper reasoning.

**Supabase.** Postgres gives us real constraints and SQL-side logic (the metrics trigger and
nightly intelligence rollup live in the database, so reporting can't drift from the source
data). Row-level security isolates each client's data for the portal; Realtime pushes
conversation/message/payment/appointment changes to the portal without polling.

**Caddy.** Terminates TLS with automatic certificate management and is the single public
ingress; n8n is published only to localhost behind it.

## The compliance gate (the part that makes it deployable)

A demo that texts people is easy. A system a regulated business will actually deploy has to
make the unglamorous guarantees, and make them in code rather than trusting the model:

- **Opt-out is a hard stop.** A `do_not_contact` row blocks the send instantly — opt-out is
  honored the moment it's recorded, not on the next batch.
- **TCPA time-of-day.** The gate computes "now" in the contact's timezone and refuses to send
  during the configured quiet-hours window (wrapping midnight correctly).
- **Frequency cap.** Per-contact daily message limits prevent harassment and protect the
  10DLC sender reputation.
- **HIPAA.** For `hipaa_mode` clients, a PHI content filter blocks anything that looks like
  protected health info from leaving over SMS and routes it to a human.

Every decision is recorded as `compliance_flags` on the message row — passed or blocked — so
there is an auditable trail. This is the difference between a chatbot demo and something a
roofer or a dental office can put on real customer traffic.

## The data moat

Every conversation is logged in a structured form: vertical, trigger, objection category,
resolution strategy, outcome, revenue recovered. `aggregate_daily_intelligence()` rolls those
into the `vertical_intelligence` table as win rates per (objection, strategy). `build_context`
then feeds the **highest-converting** strategies back into the next generation as a ranked
playbook. The system's recommendations improve as it accumulates outcomes — and that
structured corpus is the primary durable asset.

## Reliability

- **Validation at the boundary** (`validate_payload`) rejects malformed triggers before they
  reach the paid Claude/Twilio path.
- **Per-listing try/catch** in parsers so one bad record can't kill a batch.
- **Error supervisor + dead-letter queue** (`error_log`, `dead_letter_queue` tables) capture
  failed executions for retry and diagnosis rather than silently dropping them.

## Known gaps / roadmap (honest)

This reference rebuild reconstructs the deployed stack from its design. The natural next
increments — and the ones that turn it from a strong pipeline into a frontier-grade system —
are a retrieval layer (pgvector over each client's objection corpus instead of seed rows),
turning the linear pipeline into a true plan-and-execute agent with tool use, and an evaluation
harness (LLM-as-judge over a labeled set) wired into CI so prompt changes are measured, not
guessed.
