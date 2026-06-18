/**
 * Iron Forge — Code Node: validate_payload
 * Stage 1 of the universal pipeline (Trigger Ingestion).
 *
 * Validates the inbound trigger webhook before any downstream work.
 * A malformed payload is rejected here, loudly, rather than failing
 * deep in the Claude/Twilio path. n8n Code Node ("Run Once for All Items").
 *
 * Expected webhook body:
 *   { client_id, trigger_type, contact: { phone, name?, email? },
 *     trigger_data?: {...} }
 */

const REQUIRED_TRIGGER_TYPES = [
  'missed_call',
  'dead_quote',
  'unpaid_invoice',
  'treatment_incomplete',
];

// E.164-ish: optional +, 10–15 digits.
const PHONE_RE = /^\+?[1-9]\d{9,14}$/;

function fail(reason, payload) {
  // Surfaces as a node error → routed to the Error Supervisor / DLQ.
  throw new Error(`validate_payload: ${reason} :: ${JSON.stringify(payload)}`);
}

const out = [];

for (const item of $input.all()) {
  const body = item.json.body ?? item.json; // webhook node nests under .body
  const errors = [];

  if (!body || typeof body !== 'object') fail('empty or non-object body', body);

  if (!body.client_id) errors.push('missing client_id');
  if (!body.trigger_type) errors.push('missing trigger_type');
  else if (!REQUIRED_TRIGGER_TYPES.includes(body.trigger_type)) {
    errors.push(`unknown trigger_type "${body.trigger_type}"`);
  }

  const contact = body.contact ?? {};
  const phone = (contact.phone ?? '').toString().trim();
  if (!phone) errors.push('missing contact.phone');
  else if (!PHONE_RE.test(phone)) errors.push(`invalid phone "${phone}"`);

  if (errors.length) fail(errors.join('; '), body);

  out.push({
    json: {
      client_id: body.client_id,
      trigger_type: body.trigger_type,
      contact: {
        phone,
        name: contact.name ?? null,
        email: contact.email ?? null,
      },
      trigger_data: body.trigger_data ?? {},
      received_at: $now.toISO(),
    },
  });
}

return out;
