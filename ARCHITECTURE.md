# Architecture

Notes on how Iron Forge is put together and why I made the calls I made.

## One architecture, swappable verticals

The same seven-stage pipeline runs for every vertical. Standing up a new one (roofing dead-quotes,
dental unpaid-invoices) changes three things and nothing else:

1. Trigger source: which CRM/PMS/AMS event starts the conversation.
2. System prompt: the vertical's voice and selling logic (`prompts/`).
3. Objection list: the seed rows in `vertical_intelligence` for that vertical.

Everything else (enrichment, generation, compliance, delivery, logging) is shared code. That's the
whole point: a new vertical is a prompt and data job, not an engineering job.

## Data flow

```
  Client system --(webhook)-->  1. Trigger ingestion (n8n)
                                    validate_payload.js
                                    |
                                    v
                                Supabase: upsert contact, open conversation
                                    |
                                    v
                                2. Context enrichment
                                    build_context.js  <- client + history + ranked strategies
                                    |
                                    v
                                3. AI generation
                                    claude_generate.js -> Anthropic Messages API
                                    (structured output: sms_text + metadata only)
                                    |
                                    v
                                4. Compliance gate (in code)
                                    opt-out, TCPA hours, frequency, HIPAA PHI
                                    |-- fail --> log blocked, escalate to human
                                    v pass
                                5. Delivery: Twilio send, capture message SID
                                    v
                                7. Outcome logging: structured row to Supabase
                                           |
   contact replies --(webhook)-->  6. Inbound handler
                                    intent_classifier.md -> route: payment / schedule / follow-up / human
                                    v
                                (loops back into generation or escalates)
```

## Why these pieces

**n8n, self-hosted.** The workflow graph is the core of the product, so I didn't want it billed per
operation in a SaaS I don't control. Self-hosting on one VPS keeps per-conversation cost near zero,
and that's what makes performance pricing (a cut of recovered revenue) survive at scale. The cost is
that I own uptime and upgrades, which is fine for a system whose margin depends on owning the runtime.

**Claude with structured outputs.** Stage 3 calls the Messages API with `output_config.format` and a
strict JSON schema (`additionalProperties:false`). The reason is reliability, not novelty: the model
can't return a "here's a draft" preamble or its reasoning, only the five declared fields. `sms_text`
goes to the carrier; `detected_objection_category`, `resolution_strategy`, and `sentiment` get logged;
`requires_human_escalation` lets the model hand off, and the compliance gate treats it as a hard stop.
Model is `claude-sonnet-4-6` because per-message generation at volume needs to be cheap and fast.
`CLAUDE_MODEL` swaps it to Opus for a vertical that needs deeper reasoning.

**Supabase.** Postgres gives real constraints and lets the metrics trigger and the nightly rollup live
in the database, so reporting can't drift from the source rows. RLS isolates each client's data for the
portal. Realtime pushes conversation/message/payment/appointment changes to the portal without polling.

**Caddy.** Terminates TLS with automatic certs and is the only public ingress. n8n is published to
localhost behind it.

## The compliance gate

A demo that texts people is easy. A system a regulated business will put on real traffic has to make
the boring guarantees in code, not trust the model to make them:

- Opt-out is a hard stop. A `do_not_contact` row blocks the send the moment it's written.
- TCPA time-of-day. The gate computes "now" in the contact's timezone and refuses to send during the
  quiet-hours window (it handles the window wrapping past midnight).
- Frequency cap. Per-contact daily limits, which also protect the 10DLC sender reputation.
- HIPAA. For `hipaa_mode` clients, a PHI content filter keeps anything sensitive off SMS and routes it
  to a human.

Every decision lands on the message row as `compliance_flags`, passed or blocked, so there's an audit
trail. This is the line between a chatbot demo and something a dental office can run on real customers.

## The feedback loop

Every conversation logs structured outcome data: vertical, trigger, objection, strategy, outcome,
revenue recovered. `aggregate_daily_intelligence()` rolls that into `vertical_intelligence` as win
rates per objection/strategy. `build_context` then feeds the highest-converting strategies into the
next message. The recommendations improve as outcomes accumulate, and that structured log is the asset
worth keeping.

## Reliability

- Validation at the boundary (`validate_payload`) rejects bad triggers before they hit the paid
  Claude/Twilio path.
- Parsers wrap each record in try/catch so one bad row doesn't kill a batch.
- `error_log` and `dead_letter_queue` capture failed executions for retry and diagnosis instead of
  dropping them silently.

## What's not done

This repo reconstructs the deployed stack. The next increments, roughly in order of value:

- pgvector retrieval over each client's objection corpus, instead of seed rows.
- Turn the linear pipeline into a plan-and-execute agent with tool use.
- An eval harness (labeled set, LLM-as-judge) wired into CI so prompt changes are measured, not eyeballed.
- A real PHI classifier in place of the regex filter.
