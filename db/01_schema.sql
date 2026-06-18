-- ==============================================================
-- IRON FORGE — Supabase Database Schema
-- Ironline Response LLC
-- File 1 of 2 — RUN THIS FIRST
-- ==============================================================
-- Run this in Supabase SQL Editor to create all tables.
-- This schema supports: Contact Memory, Conversation Tracking,
-- Vertical Intelligence, Client Profiles, Compliance, and
-- the foundation for all 15 Arsenal features.
-- ==============================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ==============================================================
-- CLIENTS (Ironline's paying customers — the businesses)
-- ==============================================================
CREATE TABLE clients (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Identity
    business_name TEXT NOT NULL,
    vertical TEXT NOT NULL,
    owner_name TEXT,
    owner_phone TEXT,
    owner_email TEXT,
    timezone TEXT DEFAULT 'America/Chicago',

    -- API & Authentication
    api_key TEXT UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(32), 'hex'),
    webhook_secret TEXT DEFAULT encode(gen_random_bytes(16), 'hex'),

    -- Twilio Configuration
    twilio_phone_number TEXT,
    twilio_messaging_service_sid TEXT,

    -- Stripe Configuration
    stripe_account_id TEXT,
    stripe_enabled BOOLEAN DEFAULT false,

    -- Calendar Configuration
    google_calendar_id TEXT,
    appointment_duration_minutes INTEGER DEFAULT 60,
    appointment_buffer_minutes INTEGER DEFAULT 15,

    -- Brand & Messaging
    brand_voice TEXT DEFAULT 'professional and friendly',
    system_prompt_override TEXT,
    approved_offers JSONB DEFAULT '[]'::jsonb,
    max_discount_percent NUMERIC(5,2) DEFAULT 0,
    payment_plans_enabled BOOLEAN DEFAULT true,
    max_installments INTEGER DEFAULT 4,

    -- Business Hours
    business_hours JSONB DEFAULT '{
        "monday": {"start": "08:00", "end": "20:00"},
        "tuesday": {"start": "08:00", "end": "20:00"},
        "wednesday": {"start": "08:00", "end": "20:00"},
        "thursday": {"start": "08:00", "end": "20:00"},
        "friday": {"start": "08:00", "end": "20:00"},
        "saturday": {"start": "09:00", "end": "17:00"},
        "sunday": null
    }'::jsonb,

    -- Compliance
    sms_daily_limit_per_contact INTEGER DEFAULT 3,
    sms_quiet_hours_start TIME DEFAULT '21:00',
    sms_quiet_hours_end TIME DEFAULT '08:00',
    hipaa_mode BOOLEAN DEFAULT false,

    -- Performance Metrics
    total_revenue_recovered NUMERIC(12,2) DEFAULT 0,
    total_conversations INTEGER DEFAULT 0,
    conversion_rate NUMERIC(5,4) DEFAULT 0,
    avg_time_to_close_hours NUMERIC(8,2) DEFAULT 0,

    -- Billing
    billing_tier TEXT DEFAULT 'performance_pure',
    base_monthly_fee NUMERIC(8,2) DEFAULT 0,
    performance_fee_percent NUMERIC(5,2) DEFAULT 15.00,
    status TEXT DEFAULT 'active'
);

-- ==============================================================
-- CONTACTS (The people the Forge communicates with)
-- ==============================================================
CREATE TABLE contacts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,

    phone TEXT NOT NULL,
    name TEXT,
    email TEXT,

    preferred_language TEXT DEFAULT 'en',
    preferred_contact_time TEXT,
    engagement_score NUMERIC(5,2) DEFAULT 50.00,
    sentiment_trend JSONB DEFAULT '[]'::jsonb,
    tags JSONB DEFAULT '[]'::jsonb,

    objections JSONB DEFAULT '[]'::jsonb,

    status TEXT DEFAULT 'active',
    opted_out_at TIMESTAMPTZ,

    next_scheduled_contact TIMESTAMPTZ,
    contact_cadence_hours INTEGER DEFAULT 24,

    lead_score NUMERIC(5,2),
    lead_score_updated_at TIMESTAMPTZ,

    UNIQUE(client_id, phone)
);

CREATE INDEX idx_contacts_client_id ON contacts(client_id);
CREATE INDEX idx_contacts_phone ON contacts(phone);
CREATE INDEX idx_contacts_status ON contacts(status);
CREATE INDEX idx_contacts_next_contact ON contacts(next_scheduled_contact);

-- ==============================================================
-- CONVERSATIONS
-- ==============================================================
CREATE TABLE conversations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    contact_id UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,

    vertical TEXT NOT NULL,
    trigger_type TEXT NOT NULL,
    trigger_data JSONB DEFAULT '{}'::jsonb,

    potential_value NUMERIC(12,2),
    recovered_value NUMERIC(12,2) DEFAULT 0,

    status TEXT DEFAULT 'active',
    outcome_reason TEXT,

    message_count INTEGER DEFAULT 0,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    time_to_resolution_hours NUMERIC(8,2),

    ab_variant TEXT,

    appointment_booked BOOLEAN DEFAULT false,
    appointment_datetime TIMESTAMPTZ,
    payment_collected BOOLEAN DEFAULT false,
    payment_amount NUMERIC(12,2) DEFAULT 0,
    payment_stripe_id TEXT
);

CREATE INDEX idx_conversations_client_id ON conversations(client_id);
CREATE INDEX idx_conversations_contact_id ON conversations(contact_id);
CREATE INDEX idx_conversations_status ON conversations(status);
CREATE INDEX idx_conversations_trigger ON conversations(trigger_type);
CREATE INDEX idx_conversations_created ON conversations(created_at);

-- ==============================================================
-- MESSAGES
-- ==============================================================
CREATE TABLE messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),

    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    contact_id UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,

    direction TEXT NOT NULL,
    body TEXT NOT NULL,
    language TEXT DEFAULT 'en',

    twilio_message_sid TEXT,
    delivery_status TEXT,

    intent TEXT,
    sentiment TEXT,
    sentiment_intensity NUMERIC(3,1),
    detected_objection_category TEXT,

    system_prompt_version TEXT,
    strategy_used TEXT,
    -- NOTE: 'claude-sonnet-4-20250514' is DEPRECATED (retires 2026-06-15).
    -- The rebuild writes the live model id (CLAUDE_MODEL, default claude-sonnet-4-6)
    -- into this column at insert time. Update this default when convenient.
    model_used TEXT DEFAULT 'claude-sonnet-4-20250514',
    tokens_used INTEGER,

    compliance_passed BOOLEAN DEFAULT true,
    compliance_flags JSONB DEFAULT '[]'::jsonb
);

CREATE INDEX idx_messages_conversation_id ON messages(conversation_id);
CREATE INDEX idx_messages_created ON messages(created_at);
CREATE INDEX idx_messages_direction ON messages(direction);

-- ==============================================================
-- VERTICAL INTELLIGENCE
-- ==============================================================
CREATE TABLE vertical_intelligence (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    vertical TEXT NOT NULL,
    trigger_type TEXT NOT NULL,

    objection_category TEXT NOT NULL,
    resolution_strategy TEXT NOT NULL,

    times_used INTEGER DEFAULT 0,
    times_converted INTEGER DEFAULT 0,
    conversion_rate NUMERIC(5,4) DEFAULT 0,
    avg_revenue_recovered NUMERIC(12,2) DEFAULT 0,

    effective_for_amount_range_low NUMERIC(12,2),
    effective_for_amount_range_high NUMERIC(12,2),
    effective_time_of_day TEXT,

    UNIQUE(vertical, trigger_type, objection_category, resolution_strategy)
);

CREATE INDEX idx_vi_vertical ON vertical_intelligence(vertical);
CREATE INDEX idx_vi_trigger ON vertical_intelligence(trigger_type);

-- ==============================================================
-- DO NOT CONTACT
-- ==============================================================
CREATE TABLE do_not_contact (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    phone TEXT NOT NULL,
    client_id UUID REFERENCES clients(id),
    reason TEXT DEFAULT 'opt_out',

    UNIQUE(phone, client_id)
);

CREATE INDEX idx_dnc_phone ON do_not_contact(phone);

-- ==============================================================
-- ERROR LOG
-- ==============================================================
CREATE TABLE error_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),

    workflow_name TEXT NOT NULL,
    node_name TEXT,
    error_type TEXT,
    error_message TEXT,
    input_data JSONB,
    resolution TEXT,
    retry_count INTEGER DEFAULT 0,
    resolved_at TIMESTAMPTZ
);

-- ==============================================================
-- DEAD LETTER QUEUE
-- ==============================================================
CREATE TABLE dead_letter_queue (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),

    workflow_name TEXT NOT NULL,
    execution_id TEXT,
    error_type TEXT,
    error_message TEXT,
    input_data JSONB,
    retry_count INTEGER DEFAULT 0,
    last_retry_at TIMESTAMPTZ,
    status TEXT DEFAULT 'pending',
    diagnostic_report TEXT
);

-- ==============================================================
-- PAYMENTS
-- ==============================================================
CREATE TABLE payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),

    conversation_id UUID REFERENCES conversations(id),
    contact_id UUID NOT NULL REFERENCES contacts(id),
    client_id UUID NOT NULL REFERENCES clients(id),

    stripe_payment_intent_id TEXT,
    stripe_checkout_session_id TEXT,
    stripe_subscription_id TEXT,

    amount NUMERIC(12,2) NOT NULL,
    currency TEXT DEFAULT 'usd',
    is_payment_plan BOOLEAN DEFAULT false,
    installment_number INTEGER,
    total_installments INTEGER,

    status TEXT DEFAULT 'pending',
    completed_at TIMESTAMPTZ
);

CREATE INDEX idx_payments_conversation ON payments(conversation_id);
CREATE INDEX idx_payments_client ON payments(client_id);

-- ==============================================================
-- APPOINTMENTS
-- ==============================================================
CREATE TABLE appointments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at TIMESTAMPTZ DEFAULT NOW(),

    conversation_id UUID REFERENCES conversations(id),
    contact_id UUID NOT NULL REFERENCES contacts(id),
    client_id UUID NOT NULL REFERENCES clients(id),

    scheduled_at TIMESTAMPTZ NOT NULL,
    duration_minutes INTEGER DEFAULT 60,
    google_calendar_event_id TEXT,

    reminder_24h_sent BOOLEAN DEFAULT false,
    reminder_2h_sent BOOLEAN DEFAULT false,

    status TEXT DEFAULT 'scheduled',
    estimated_value NUMERIC(12,2)
);

CREATE INDEX idx_appointments_client ON appointments(client_id);
CREATE INDEX idx_appointments_scheduled ON appointments(scheduled_at);

-- ==============================================================
-- HELPER FUNCTIONS
-- ==============================================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_clients_updated BEFORE UPDATE ON clients
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER tr_contacts_updated BEFORE UPDATE ON contacts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER tr_conversations_updated BEFORE UPDATE ON conversations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE FUNCTION calculate_engagement_score(p_contact_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_score NUMERIC := 50;
    v_response_rate NUMERIC;
    v_avg_sentiment NUMERIC;
    v_recent_activity BOOLEAN;
    v_has_converted BOOLEAN;
BEGIN
    SELECT
        COALESCE(
            COUNT(*) FILTER (WHERE direction = 'inbound')::NUMERIC /
            NULLIF(COUNT(*) FILTER (WHERE direction = 'outbound'), 0),
            0
        )
    INTO v_response_rate
    FROM messages
    WHERE contact_id = p_contact_id;

    SELECT COALESCE(AVG(
        CASE sentiment
            WHEN 'positive' THEN 80
            WHEN 'neutral' THEN 50
            WHEN 'confused' THEN 40
            WHEN 'anxious' THEN 35
            WHEN 'frustrated' THEN 20
            WHEN 'angry' THEN 10
            ELSE 50
        END
    ), 50)
    INTO v_avg_sentiment
    FROM messages
    WHERE contact_id = p_contact_id AND direction = 'inbound';

    SELECT EXISTS(
        SELECT 1 FROM messages
        WHERE contact_id = p_contact_id
        AND direction = 'inbound'
        AND created_at > NOW() - INTERVAL '7 days'
    ) INTO v_recent_activity;

    SELECT EXISTS(
        SELECT 1 FROM conversations
        WHERE contact_id = p_contact_id AND status = 'converted'
    ) INTO v_has_converted;

    v_score := (v_response_rate * 30) + (v_avg_sentiment * 0.4);
    IF v_recent_activity THEN v_score := v_score + 15; END IF;
    IF v_has_converted THEN v_score := v_score + 10; END IF;

    v_score := GREATEST(0, LEAST(100, v_score));

    UPDATE contacts SET engagement_score = v_score WHERE id = p_contact_id;

    RETURN v_score;
END;
$$ LANGUAGE plpgsql;

-- ==============================================================
-- ROW LEVEL SECURITY
-- ==============================================================
ALTER TABLE clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access" ON clients FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON contacts FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON conversations FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON messages FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON payments FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON appointments FOR ALL USING (true) WITH CHECK (true);

-- ==============================================================
-- SEED DATA: Initial vertical intelligence entries
-- ==============================================================
INSERT INTO vertical_intelligence (vertical, trigger_type, objection_category, resolution_strategy, times_used, times_converted, conversion_rate) VALUES
('roofing', 'dead_quote', 'price', 'warranty_comparison', 0, 0, 0),
('roofing', 'dead_quote', 'price', 'material_grade_highlight', 0, 0, 0),
('roofing', 'dead_quote', 'price', 'financing_offer', 0, 0, 0),
('roofing', 'dead_quote', 'timing', 'crew_availability_urgency', 0, 0, 0),
('roofing', 'dead_quote', 'timing', 'seasonal_pricing_alert', 0, 0, 0),
('roofing', 'dead_quote', 'competitor', 'licensing_verification', 0, 0, 0),
('roofing', 'dead_quote', 'competitor', 'review_comparison', 0, 0, 0),
('roofing', 'dead_quote', 'trust', 'social_proof_local', 0, 0, 0),
('roofing', 'dead_quote', 'trust', 'insurance_and_bond_highlight', 0, 0, 0),
('dental', 'unpaid_invoice', 'financial_hardship', 'payment_plan_normalized', 0, 0, 0),
('dental', 'unpaid_invoice', 'financial_hardship', 'sliding_scale', 0, 0, 0),
('dental', 'unpaid_invoice', 'forgot', 'gentle_reminder_with_link', 0, 0, 0),
('dental', 'unpaid_invoice', 'dispute', 'acknowledge_and_escalate', 0, 0, 0),
('dental', 'unpaid_invoice', 'insurance_confusion', 'benefits_explanation', 0, 0, 0),
('dental', 'treatment_incomplete', 'fear', 'reassurance_and_options', 0, 0, 0),
('dental', 'treatment_incomplete', 'cost', 'financing_and_necessity', 0, 0, 0),
('dental', 'treatment_incomplete', 'scheduling', 'flexible_availability', 0, 0, 0);
