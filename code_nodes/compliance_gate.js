/**
 * Iron Forge — Code Node: compliance_gate
 * Stage 4 of the universal pipeline (Compliance Gate).
 *
 * Compliance is enforced in CODE, not left to the model. NOTHING sends
 * until this passes. Checks, in order:
 *   1. Opt-out / do-not-contact (hard stop, instant honoring)
 *   2. TCPA time-of-day window (no SMS during the contact's quiet hours)
 *   3. Message-frequency cap (per-contact daily limit)
 *   4. HIPAA content filter (no PHI in SMS for healthcare verticals)
 *
 * Emits compliance_passed + compliance_flags, which are logged on the
 * message row regardless of outcome (auditable compliance trail).
 *
 * Upstream:
 *   - $('build_context')        → context + client_id + contact_phone
 *   - $('supabase_client')      → client row (quiet hours, limits, hipaa_mode)
 *   - $('supabase_dnc')         → do_not_contact match (array; empty = clear)
 *   - $('supabase_today_count') → { count } outbound msgs to contact today
 *   - $('claude_generate')      → { sms_text } candidate message
 */

const ctx = $('build_context').first().json;
const client = $('supabase_client').first().json;
const dncHits = $('supabase_dnc').all() ?? [];
const todayCount = Number($('supabase_today_count').first()?.json?.count ?? 0);
const candidate = $('claude_generate').first().json;

const flags = [];
let passed = true;

// --- 1. Opt-out / DNC: hard stop -------------------------------------------
if (dncHits.length > 0) {
  flags.push('opted_out');
  passed = false;
}

// --- 2. TCPA time-of-day window --------------------------------------------
// Compare "now" in the client's timezone against their quiet-hours window.
const tz = client.timezone || 'America/Chicago';
const nowParts = new Intl.DateTimeFormat('en-US', {
  timeZone: tz,
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
}).formatToParts(new Date());
const hh = Number(nowParts.find((p) => p.type === 'hour').value);
const mm = Number(nowParts.find((p) => p.type === 'minute').value);
const nowMin = hh * 60 + mm;

const toMin = (t) => {
  const [h, m] = String(t).split(':').map(Number);
  return h * 60 + m;
};
const quietStart = toMin(client.sms_quiet_hours_start || '21:00');
const quietEnd = toMin(client.sms_quiet_hours_end || '08:00');

// Quiet window wraps midnight (e.g. 21:00 → 08:00).
const inQuietHours =
  quietStart > quietEnd
    ? nowMin >= quietStart || nowMin < quietEnd
    : nowMin >= quietStart && nowMin < quietEnd;

if (inQuietHours) {
  flags.push('tcpa_quiet_hours');
  passed = false;
}

// --- 3. Frequency cap ------------------------------------------------------
const dailyLimit = Number(client.sms_daily_limit_per_contact ?? 3);
if (todayCount >= dailyLimit) {
  flags.push('frequency_limit');
  passed = false;
}

// --- 4. HIPAA content filter (healthcare verticals only) -------------------
if (client.hipaa_mode) {
  const text = (candidate?.sms_text ?? '').toLowerCase();
  // Conservative PHI signal list. A hit blocks the send for human review
  // rather than risking protected health info over SMS.
  const PHI_PATTERNS = [
    /\bdiagnos(is|ed|es)\b/,
    /\bprescrib(e|ed|ing)\b/,
    /\bmedication\b/,
    /\btreatment\s+for\b/,
    /\bprocedure\b/,
    /\blab\s+result/,
    /\btest\s+result/,
  ];
  if (PHI_PATTERNS.some((re) => re.test(text))) {
    flags.push('hipaa_phi_suspected');
    passed = false;
  }
}

// candidate may also self-report it needs a human (from the model's schema).
if (candidate?.requires_human_escalation) {
  flags.push('model_requested_escalation');
  passed = false;
}

return [
  {
    json: {
      ...ctx,
      sms_text: candidate?.sms_text ?? null,
      detected_objection_category: candidate?.detected_objection_category ?? null,
      resolution_strategy: candidate?.resolution_strategy ?? null,
      sentiment: candidate?.sentiment ?? null,
      compliance_passed: passed,
      compliance_flags: flags,
    },
  },
];
