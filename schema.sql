-- AI Sales Agent Template — consolidated schema (PostgreSQL 13+)
-- Idempotent. No business data.
-- Apply: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/schema.sql
--
-- Memory table `n8n_chat_histories` is normally created by the n8n Postgres Chat
-- Memory node. It is declared here identically so a fresh database works before
-- the first agent call.

BEGIN;

-- ---------------------------------------------------------------- tenants
CREATE TABLE IF NOT EXISTS tenants (
  tenant_id        text PRIMARY KEY,
  business_name    text NOT NULL,
  channel          text NOT NULL DEFAULT 'instagram',
  external_page_id text UNIQUE NOT NULL,
  config           jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, channel)
);

CREATE TABLE IF NOT EXISTS tenant_prompts (
  id            bigserial PRIMARY KEY,
  tenant_id     text NOT NULL,
  version       int NOT NULL,
  system_prompt text NOT NULL,
  is_active     boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS tenant_prompts_one_active
  ON tenant_prompts (tenant_id) WHERE is_active;

CREATE TABLE IF NOT EXISTS tenant_kb (
  tenant_id text NOT NULL,
  key       text NOT NULL,
  value     text NOT NULL,
  PRIMARY KEY (tenant_id, key)
);

-- ------------------------------------------------------------------ leads
CREATE TABLE IF NOT EXISTS leads (
  id                   bigserial PRIMARY KEY,
  tenant_id            text NOT NULL,
  channel              text NOT NULL DEFAULT 'instagram',
  customer_id          text NOT NULL,
  username             text,
  display_name         text,
  phone                text,
  service_interest     text,
  city                 text,
  lead_status          text NOT NULL DEFAULT 'in_progress'
                       CHECK (lead_status IN ('in_progress','interested','qualified','handover','not_lead')),
  lead_data            jsonb NOT NULL DEFAULT '{}'::jsonb,
  summary              text,
  muted_until          timestamptz,
  lead_notified_at     timestamptz,
  handover_required    boolean NOT NULL DEFAULT false,
  handover_reason      text,
  handover_notified_at timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, channel, customer_id)
);
CREATE INDEX IF NOT EXISTS leads_open_handover_idx
  ON leads (tenant_id) WHERE handover_required AND handover_notified_at IS NULL;

-- ------------------------------------------------------- webhook reliability
CREATE TABLE IF NOT EXISTS processed_messages (
  mid        text PRIMARY KEY,
  tenant_id  text,
  channel    text,
  event      jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS processed_messages_tenant_idx
  ON processed_messages (tenant_id, created_at DESC);

CREATE TABLE IF NOT EXISTS pending_messages (
  id           bigserial PRIMARY KEY,
  tenant_id    text NOT NULL,
  channel      text NOT NULL DEFAULT 'instagram',
  customer_id  text NOT NULL,
  mid          text UNIQUE,
  text_b64     text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);
CREATE INDEX IF NOT EXISTS pending_messages_open
  ON pending_messages (tenant_id, channel, customer_id) WHERE processed_at IS NULL;

CREATE TABLE IF NOT EXISTS unsupported_replies (
  id          bigserial PRIMARY KEY,
  tenant_id   text NOT NULL,
  channel     text NOT NULL DEFAULT 'instagram',
  customer_id text NOT NULL,
  sent_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS unsupported_replies_window
  ON unsupported_replies (tenant_id, channel, customer_id, sent_at DESC);

CREATE TABLE IF NOT EXISTS ignored_events (
  id         bigserial PRIMARY KEY,
  tenant_id  text,
  page_id    text,
  kind       text NOT NULL,
  mid        text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ignored_events_kind_idx
  ON ignored_events (kind, created_at DESC);

CREATE TABLE IF NOT EXISTS sent_messages (
  id                  bigserial PRIMARY KEY,
  tenant_id           text NOT NULL,
  channel             text NOT NULL DEFAULT 'instagram',
  customer_id         text NOT NULL,
  external_message_id text UNIQUE,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sent_messages_customer_idx
  ON sent_messages (tenant_id, channel, customer_id, created_at DESC);

-- --------------------------------------------------------------- telemetry
CREATE TABLE IF NOT EXISTS metrics (
  id                bigserial PRIMARY KEY,
  tenant_id         text NOT NULL,
  channel           text NOT NULL DEFAULT 'instagram',
  customer_id       text,
  message_id        text,
  message_type      text,
  message_length    int,
  language          text,
  ai_model          text,
  ai_latency_ms     int,
  total_latency_ms  int,
  is_lead           boolean,
  lead_status       text,
  handover_required boolean,
  extracted_data    jsonb,
  ig_send_status    int,
  chunks_count      int,
  tokens_in         int,
  tokens_out        int,
  execution_id      text,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS metrics_tenant_idx ON metrics (tenant_id, created_at DESC);

CREATE TABLE IF NOT EXISTS error_log (
  id            bigserial PRIMARY KEY,
  tenant_id     text,
  node_name     text,
  error_message text,
  execution_id  text,
  customer_id   text,
  message_id    text,
  error_stage   text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS error_log_tenant_idx ON error_log (tenant_id, created_at DESC);

-- ------------------------------------------------------------ chat memory
CREATE TABLE IF NOT EXISTS n8n_chat_histories (
  id         SERIAL PRIMARY KEY,
  session_id VARCHAR(255) NOT NULL,
  message    JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS n8n_chat_histories_session_idx
  ON n8n_chat_histories (session_id);

COMMIT;
