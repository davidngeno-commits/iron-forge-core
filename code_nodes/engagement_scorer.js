// engagement_scorer: support node. Client-side mirror of the SQL function
// calculate_engagement_score(). Prefer the SQL function; it owns the canonical
// formula. This exists for flows that need a score in-memory without a DB
// round-trip. Score 0-100: response_rate*30 + avg_sentiment*0.4, +15 if active
// in the last 7 days, +10 if ever converted.

const SENTIMENT_WEIGHT = {
  positive: 80,
  neutral: 50,
  confused: 40,
  anxious: 35,
  frustrated: 20,
  angry: 10,
};

function scoreContact(messages, hasConverted) {
  const inbound = messages.filter((m) => m.direction === 'inbound');
  const outbound = messages.filter((m) => m.direction === 'outbound');

  const responseRate = outbound.length ? inbound.length / outbound.length : 0;

  const sentiments = inbound
    .map((m) => SENTIMENT_WEIGHT[m.sentiment] ?? 50)
    .filter((n) => Number.isFinite(n));
  const avgSentiment = sentiments.length
    ? sentiments.reduce((a, b) => a + b, 0) / sentiments.length
    : 50;

  const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const recentlyActive = inbound.some(
    (m) => new Date(m.created_at).getTime() > sevenDaysAgo,
  );

  let score = responseRate * 30 + avgSentiment * 0.4;
  if (recentlyActive) score += 15;
  if (hasConverted) score += 10;

  return Math.max(0, Math.min(100, Math.round(score * 100) / 100));
}

return $input.all().map((item) => {
  const { messages = [], has_converted = false, contact_id = null } = item.json;
  return {
    json: {
      contact_id,
      engagement_score: scoreContact(messages, has_converted),
      scored_at: $now.toISO(),
    },
  };
});
