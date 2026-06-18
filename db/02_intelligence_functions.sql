-- Iron Forge: Supabase functions, triggers, realtime. Run after 01_schema.sql.
-- Auto-updated client metrics, the nightly intelligence rollup, one-call client
-- onboarding, and the realtime + RLS setup for the client portal.

-- ==============================================================
-- 1. AUTO-UPDATE CLIENT METRICS WHEN A CONVERSATION CONVERTS
-- ==============================================================
-- Keeps clients.total_revenue_recovered / total_conversations /
-- conversion_rate / avg_time_to_close_hours in sync with reality so
-- the portal never drifts from the conversations table.
CREATE OR REPLACE FUNCTION refresh_client_metrics(p_client_id UUID)
RETURNS VOID AS $$
DECLARE
    v_total_convos     INTEGER;
    v_converted        INTEGER;
    v_revenue          NUMERIC(12,2);
    v_avg_close        NUMERIC(8,2);
BEGIN
    SELECT
        COUNT(*),
        COUNT(*) FILTER (WHERE status = 'converted'),
        COALESCE(SUM(recovered_value), 0),
        COALESCE(AVG(time_to_resolution_hours) FILTER (WHERE status = 'converted'), 0)
    INTO v_total_convos, v_converted, v_revenue, v_avg_close
    FROM conversations
    WHERE client_id = p_client_id;

    UPDATE clients
    SET total_conversations    = v_total_convos,
        total_revenue_recovered = v_revenue,
        avg_time_to_close_hours = v_avg_close,
        conversion_rate         = CASE WHEN v_total_convos > 0
                                       THEN ROUND(v_converted::NUMERIC / v_total_convos, 4)
                                       ELSE 0 END,
        updated_at              = NOW()
    WHERE id = p_client_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tr_conversation_metrics()
RETURNS TRIGGER AS $$
BEGIN
    -- Only recompute when a conversion-relevant field actually changed.
    IF (TG_OP = 'INSERT')
       OR NEW.status IS DISTINCT FROM OLD.status
       OR NEW.recovered_value IS DISTINCT FROM OLD.recovered_value THEN
        PERFORM refresh_client_metrics(NEW.client_id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_conversations_metrics
    AFTER INSERT OR UPDATE ON conversations
    FOR EACH ROW EXECUTE FUNCTION tr_conversation_metrics();

-- ==============================================================
-- 2. NIGHTLY VERTICAL-INTELLIGENCE AGGREGATION
-- ==============================================================
-- Rolls each (vertical, trigger, objection, strategy) tuple's win rate
-- up from the message/conversation log. Schedule via pg_cron (below) or
-- an n8n nightly trigger calling: SELECT aggregate_daily_intelligence();
CREATE OR REPLACE FUNCTION aggregate_daily_intelligence()
RETURNS INTEGER AS $$
DECLARE
    v_rows INTEGER := 0;
BEGIN
    WITH stats AS (
        SELECT
            c.vertical,
            c.trigger_type,
            m.detected_objection_category AS objection_category,
            m.strategy_used               AS resolution_strategy,
            COUNT(*)                                                  AS uses,
            COUNT(*) FILTER (WHERE c.status = 'converted')            AS wins,
            COALESCE(AVG(c.recovered_value)
                     FILTER (WHERE c.status = 'converted'), 0)        AS avg_rev
        FROM messages m
        JOIN conversations c ON c.id = m.conversation_id
        WHERE m.direction = 'outbound'
          AND m.strategy_used IS NOT NULL
          AND m.detected_objection_category IS NOT NULL
        GROUP BY 1, 2, 3, 4
    )
    INSERT INTO vertical_intelligence AS vi
        (vertical, trigger_type, objection_category, resolution_strategy,
         times_used, times_converted, conversion_rate, avg_revenue_recovered, updated_at)
    SELECT
        vertical, trigger_type, objection_category, resolution_strategy,
        uses, wins,
        CASE WHEN uses > 0 THEN ROUND(wins::NUMERIC / uses, 4) ELSE 0 END,
        avg_rev, NOW()
    FROM stats
    ON CONFLICT (vertical, trigger_type, objection_category, resolution_strategy)
    DO UPDATE SET
        times_used            = EXCLUDED.times_used,
        times_converted       = EXCLUDED.times_converted,
        conversion_rate       = EXCLUDED.conversion_rate,
        avg_revenue_recovered = EXCLUDED.avg_revenue_recovered,
        updated_at            = NOW();

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$ LANGUAGE plpgsql;

-- Optional: schedule nightly at 03:00 UTC if pg_cron is available.
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('iron-forge-nightly-intel', '0 3 * * *',
--                      $$SELECT aggregate_daily_intelligence();$$);

-- ==============================================================
-- 3. ONE-CALL CLIENT ONBOARDING
-- ==============================================================
-- Creates a client row and maps a Supabase auth user to it in one call,
-- returning the new client_id. Used by the onboarding workflow.
CREATE OR REPLACE FUNCTION onboard_client(
    p_business_name TEXT,
    p_vertical      TEXT,
    p_owner_name    TEXT DEFAULT NULL,
    p_owner_email   TEXT DEFAULT NULL,
    p_owner_phone   TEXT DEFAULT NULL,
    p_auth_user_id  UUID DEFAULT NULL,
    p_timezone      TEXT DEFAULT 'America/Chicago'
)
RETURNS UUID AS $$
DECLARE
    v_client_id UUID;
BEGIN
    INSERT INTO clients (business_name, vertical, owner_name, owner_email, owner_phone, timezone)
    VALUES (p_business_name, p_vertical, p_owner_name, p_owner_email, p_owner_phone, p_timezone)
    RETURNING id INTO v_client_id;

    IF p_auth_user_id IS NOT NULL THEN
        INSERT INTO client_users (client_id, auth_user_id, role)
        VALUES (v_client_id, p_auth_user_id, 'owner')
        ON CONFLICT (auth_user_id) DO UPDATE SET client_id = EXCLUDED.client_id;
    END IF;

    RETURN v_client_id;
END;
$$ LANGUAGE plpgsql;

-- ==============================================================
-- 4. CLIENT_USERS (portal auth mapping) + tenant-scoped RLS
-- ==============================================================
CREATE TABLE IF NOT EXISTS client_users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    auth_user_id UUID NOT NULL UNIQUE,   -- references auth.users(id)
    role TEXT DEFAULT 'member'
);
CREATE INDEX IF NOT EXISTS idx_client_users_auth ON client_users(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_client_users_client ON client_users(client_id);

ALTER TABLE client_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE do_not_contact ENABLE ROW LEVEL SECURITY;
ALTER TABLE error_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE dead_letter_queue ENABLE ROW LEVEL SECURITY;

-- Service role (n8n, server-side) keeps full access on the operational tables.
CREATE POLICY "Service role full access" ON client_users FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON do_not_contact FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON error_log FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON dead_letter_queue FOR ALL USING (true) WITH CHECK (true);

-- ------------------------------------------------------------------
-- Portal isolation: an authenticated portal user may read ONLY rows
-- belonging to their own client. Helper resolves auth.uid() -> client_id.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_portal_client_id()
RETURNS UUID AS $$
    SELECT client_id FROM client_users WHERE auth_user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE POLICY "Portal reads own client"        ON clients
    FOR SELECT TO authenticated USING (id = current_portal_client_id());
CREATE POLICY "Portal reads own contacts"      ON contacts
    FOR SELECT TO authenticated USING (client_id = current_portal_client_id());
CREATE POLICY "Portal reads own conversations" ON conversations
    FOR SELECT TO authenticated USING (client_id = current_portal_client_id());
CREATE POLICY "Portal reads own messages"      ON messages
    FOR SELECT TO authenticated USING (
        conversation_id IN (SELECT id FROM conversations WHERE client_id = current_portal_client_id())
    );
CREATE POLICY "Portal reads own payments"      ON payments
    FOR SELECT TO authenticated USING (client_id = current_portal_client_id());
CREATE POLICY "Portal reads own appointments"  ON appointments
    FOR SELECT TO authenticated USING (client_id = current_portal_client_id());

-- ==============================================================
-- 5. REALTIME: stream state changes to the portal
-- ==============================================================
-- Adds the live-updating tables to the supabase_realtime publication so
-- the client portal reflects conversation/message/payment/appointment
-- changes without polling.
ALTER PUBLICATION supabase_realtime ADD TABLE conversations;
ALTER PUBLICATION supabase_realtime ADD TABLE messages;
ALTER PUBLICATION supabase_realtime ADD TABLE payments;
ALTER PUBLICATION supabase_realtime ADD TABLE appointments;
