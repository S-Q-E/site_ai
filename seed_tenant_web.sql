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
  'Demo',
  'web',
  'demo-site-key',
  true,
  $cfg$
  {
    "business": { "name": "Demo", "description": "Описание бизнеса", "timezone": "Asia/Almaty",
                  "languages": ["ru"], "communication_tone": "дружелюбно, коротко, без канцелярита" },
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
$p$Ты — {{kb:agent_role}} компании. Отвечай на языках: {{languages}} (по умолчанию {{language_default}}).
Твоя задача — помочь клиенту и собрать данные для заявки. Обязательные поля: {{required_fields}}. Дополнительные: {{optional_fields}}.
Задавай не больше одного вопроса за раз. Не выдумывай цены и условия — используй только факты ниже.

Об услугах и ценах:
{{kb:services}}$p$,
  true
)
ON CONFLICT (tenant_id, version) DO UPDATE SET
  system_prompt = EXCLUDED.system_prompt,
  is_active     = true;

-- 3. База знаний ({{kb:agent_role}} и {{kb:services}} из промпта).
INSERT INTO tenant_kb (tenant_id, key, value)
VALUES
  ('demo_site', 'agent_role', 'консультант по продажам'),
  ('demo_site', 'services',   'Опишите услуги и цены здесь')
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
