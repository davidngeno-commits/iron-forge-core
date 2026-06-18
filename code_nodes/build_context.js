// build_context: stage 2. Merge trigger + client + history + intelligence into
// one context object that gets injected into the stage-3 Claude call.
// Upstream nodes feeding this: validate_payload, supabase_client,
// supabase_contact (null on first touch), supabase_messages, supabase_intelligence.

const trigger = $('validate_payload').first().json;
const client = $('supabase_client').first().json;
const contact = $('supabase_contact').first()?.json ?? null;
const history = ($('supabase_messages').all() ?? []).map((i) => i.json);
const intel = ($('supabase_intelligence').all() ?? []).map((i) => i.json);

// Last 12 turns only, to keep the prompt small and the call cheap.
const recentHistory = history
  .slice(-12)
  .map((m) => ({
    direction: m.direction,
    body: m.body,
    sentiment: m.sentiment ?? null,
    at: m.created_at,
  }));

// Rank strategies by real win rate so the prompt leads with what converts.
const rankedStrategies = intel
  .filter((s) => s.times_used > 0)
  .sort((a, b) => Number(b.conversion_rate) - Number(a.conversion_rate))
  .slice(0, 6)
  .map((s) => ({
    objection: s.objection_category,
    strategy: s.resolution_strategy,
    win_rate: Number(s.conversion_rate),
  }));

return [
  {
    json: {
      // Routing / identity
      client_id: trigger.client_id,
      vertical: client.vertical,
      trigger_type: trigger.trigger_type,

      // The structured context block injected into the Claude system prompt
      context: {
        business: {
          name: client.business_name,
          brand_voice: client.brand_voice,
          timezone: client.timezone,
          max_discount_percent: Number(client.max_discount_percent ?? 0),
          payment_plans_enabled: !!client.payment_plans_enabled,
          hipaa_mode: !!client.hipaa_mode,
        },
        contact: {
          id: contact?.id ?? null,
          name: trigger.contact.name ?? contact?.name ?? null,
          is_new: !contact,
          preferred_language: contact?.preferred_language ?? 'en',
          engagement_score: Number(contact?.engagement_score ?? 50),
        },
        trigger_data: trigger.trigger_data,
        conversation_history: recentHistory,
        proven_strategies: rankedStrategies,
      },

      // Pass-through for compliance + delivery stages
      contact_phone: trigger.contact.phone,
      contact_id: contact?.id ?? null,
    },
  },
];
