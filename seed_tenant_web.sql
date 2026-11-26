-- Веб-тенант для workflow "AI Sales Agent Template (Web Chat)".
-- Проверено на схеме ai-sales-agent-template/database/schema.sql (PostgreSQL 16).
-- Идемпотентно: повторный запуск обновляет тенанта, промпт и KB, а не создаёт дубликаты.
--
-- Перед запуском замените:
--   demo-site-key             → публичный ключ сайта (site_key в виджете)
--   PUT_TELEGRAM_CHAT_ID_HERE → chat_id менеджера (или telegram_enabled=false)
--   allowed_origins           → домены вашего сайта
--   agent.model               → модель OpenRouter, доступную вашему ключу

BEGIN;

-- 0. Если в таблицах есть CHECK (channel IN ('instagram')), расширьте его до 'web'.
--    Проверка:
--    SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE pg_get_constraintdef(oid) ILIKE '%instagram%';

-- 1. Тенант.
--    tenant_id и business_name обязательны в reference-схеме (NOT NULL без DEFAULT).
INSERT INTO tenants (tenant_id, business_name, channel, external_page_id, is_active, config)
VALUES (
  'demo_site',
  'Greentriangle',
  'web',
  'demo-site-key',
  true,
  $cfg$
  {
    "business": { "name": "Greentriangle", "description": "Software development, AI automation and IT consulting agency.", "timezone": "Asia/Almaty",
                  "languages": ["en", "ru"], "communication_tone": "friendly, concise, professional" },
    "agent": { "name": "Консультант", "model": "openai/gpt-4o-mini", "temperature": 0.3, "memory_window": 12 },
    "integrations": { "telegram_enabled": true, "google_sheets_enabled": false, "crm_enabled": false },
    "notifications": { "telegram_chat_id": "PUT_TELEGRAM_CHAT_ID_HERE",
                       "notify_on_qualified_lead": true, "notify_on_handover": true, "notify_on_error": true },
    "behavior": { "debounce_seconds": 0 },
    "allowed_origins": ["https://example.com", "https://www.example.com"],
    "rate_limit_per_min": 20
  }
  $cfg$::jsonb
)
ON CONFLICT (tenant_id) DO UPDATE SET
  business_name    = EXCLUDED.business_name,
  channel          = 'web',
  external_page_id = EXCLUDED.external_page_id,
  is_active        = true,
  config           = EXCLUDED.config;

-- 2. Промпт (ровно одна активная версия на тенанта).
UPDATE tenant_prompts
SET is_active = false
WHERE tenant_id = 'demo_site' AND version <> 1;

INSERT INTO tenant_prompts (tenant_id, version, system_prompt, is_active)
VALUES (
  'demo_site',
  1,
$p$LANGUAGE RULE (highest priority): Reply in the same language as the customer's latest message. If the customer writes in English, reply in English. If the customer writes in Russian, reply in Russian. Never switch language on your own.

You are the {{kb:agent_role}} at Greentriangle, a software development, AI automation and IT consulting agency. Help the customer and collect the details needed for a request.
Required fields: {{required_fields}}. Optional fields: {{optional_fields}}.
Ask at most one question at a time. Use only the facts below; never invent prices, discounts or timelines. All prices are in USD.
When the customer asks about cost, quote the relevant hourly rate or fixed-price range from the catalog and offer a short discovery call for an exact quote.
Supported languages: {{languages}} (default {{language_default}}).

Services and pricing:
{{kb:services}}$p$,
  true
)
ON CONFLICT (tenant_id, version) DO UPDATE SET
  system_prompt = EXCLUDED.system_prompt,
  is_active     = true;

-- 3. База знаний ({{kb:agent_role}} и {{kb:services}} из промпта).
INSERT INTO tenant_kb (tenant_id, key, value)
VALUES
  ('demo_site', 'agent_role', 'sales consultant'),
  ('demo_site', 'services',   'HOURLY RATES (USD/hour):
- Full-stack / web development: $55-$95
- Backend / API / integrations: $65-$110
- AI development (RAG, agents, voice): $85-$140
- Automation (n8n, Make, CRM): $60-$100
- DevOps / cloud infrastructure: $75-$125
- UI/UX design: $50-$85
- PM / tech lead / architect: $80-$135

FIXED-PRICE PROJECTS (USD):
- Custom AI assistant / turnkey RAG bot (CRM integration, knowledge base, analytics, deployment): $3,500-$8,500
- Voice AI receptionist / call center (telephony, STT/TTS, scenarios, calendar/CRM booking): $4,500-$10,000
- End-to-end business process automation (website, messengers, ERP/CRM, payments, dashboards): $4,000-$12,000
- MVP of a web service or SaaS platform (frontend, backend, database, auth, billing): $12,000-$28,000
- Monthly support and development retainer (20-40 hours + SLA): $1,500-$3,500/month')
ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;

-- Перевести существующий тенант на веб-канал вместо создания нового:
-- UPDATE tenants SET channel = 'web', external_page_id = 'demo-site-key'
-- WHERE tenant_id = '<tenant_id>';

-- Полезные поля config:
--   allowed_origins           — домены, с которых разрешён чат. Пустой список = разрешено всем.
--   rate_limit_per_min        — лимит сообщений в минуту на сессию (по умолчанию 20).
--   behavior.debounce_seconds — 0 для веб-чата, иначе ответ задерживается на N секунд.
--
-- curl при непустом allowed_origins:
--   -H 'Origin: https://example.com'
