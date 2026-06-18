/**
 * Iron Forge — Code Node: claude_generate
 * Stage 3 of the universal pipeline (AI Conversation Generation).
 *
 * Calls the Anthropic Messages API to produce the outbound SMS for a
 * vertical, using the vertical's system prompt + the injected context
 * from build_context.
 *
 * METADATA-LEAK PREVENTION:
 *   The request uses structured outputs (output_config.format, json_schema
 *   with additionalProperties:false). The model can ONLY return the declared
 *   fields — no preamble, no "Here's a draft:", no chain-of-thought. We send
 *   `sms_text` to Twilio and log the rest (objection/strategy/sentiment) to
 *   the data-moat tables. `requires_human_escalation` lets the model hand off
 *   cleanly; the compliance_gate treats it as a hard stop.
 *
 * Model: $env.CLAUDE_MODEL (default claude-sonnet-4-6) — current Sonnet is
 *   the right cost/latency tier for high-volume per-message generation and
 *   protects gross margin. Structured outputs are supported on Sonnet 4.6.
 *
 * Requires: ANTHROPIC_API_KEY in the environment (never hardcode).
 */

const ctx = $('build_context').first().json;
const model = $env.CLAUDE_MODEL || 'claude-sonnet-4-6';
const apiKey = $env.ANTHROPIC_API_KEY;
if (!apiKey) throw new Error('claude_generate: ANTHROPIC_API_KEY is not set');

// The vertical system prompt is loaded by an upstream node (Read Binary /
// HTTP / a Set node) and passed in as ctx.system_prompt. Fail loud if absent.
const systemPrompt = ctx.system_prompt;
if (!systemPrompt) {
  throw new Error('claude_generate: missing vertical system prompt (ctx.system_prompt)');
}

// Strict response contract — the leak guard.
const RESPONSE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    sms_text: { type: 'string' },
    detected_objection_category: { type: 'string' },
    resolution_strategy: { type: 'string' },
    sentiment: {
      type: 'string',
      enum: ['positive', 'neutral', 'confused', 'anxious', 'frustrated', 'angry'],
    },
    requires_human_escalation: { type: 'boolean' },
  },
  required: [
    'sms_text',
    'detected_objection_category',
    'resolution_strategy',
    'sentiment',
    'requires_human_escalation',
  ],
};

const body = {
  model,
  max_tokens: 1024,
  system: [
    { type: 'text', text: systemPrompt },
    {
      type: 'text',
      // Injected context as a separate block keeps the stable prompt prefix
      // cacheable across messages for the same vertical.
      text: 'CONTEXT (JSON):\n' + JSON.stringify(ctx.context, null, 2),
    },
  ],
  messages: [
    {
      role: 'user',
      content:
        'Generate the next outbound SMS for this contact, following the system ' +
        'instructions and the context. Return only the structured fields.',
    },
  ],
  output_config: { format: { type: 'json_schema', schema: RESPONSE_SCHEMA } },
};

const res = await fetch('https://api.anthropic.com/v1/messages', {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': '2023-06-01',
  },
  body: JSON.stringify(body),
});

if (!res.ok) {
  const errText = await res.text();
  throw new Error(`claude_generate: Anthropic API ${res.status} :: ${errText}`);
}

const data = await res.json();

// Safety refusal — surface, don't send.
if (data.stop_reason === 'refusal') {
  return [
    {
      json: {
        sms_text: null,
        requires_human_escalation: true,
        detected_objection_category: null,
        resolution_strategy: null,
        sentiment: null,
        model_used: model,
        tokens_used: data.usage?.output_tokens ?? null,
        refused: true,
      },
    },
  ];
}

// With output_config.format the first text block is guaranteed valid JSON.
const textBlock = (data.content || []).find((b) => b.type === 'text');
const parsed = JSON.parse(textBlock.text);

return [
  {
    json: {
      ...parsed,
      model_used: model,
      tokens_used:
        (data.usage?.input_tokens ?? 0) + (data.usage?.output_tokens ?? 0),
    },
  },
];
