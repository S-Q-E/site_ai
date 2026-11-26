# AI Sales Agent — веб-чат (n8n + PostgreSQL)

Workflow n8n для чат-виджета на сайте: входящий HTTP-запрос → тенант по `site_key` → AI-агент →
синхронный ответ в том же запросе. Дальше — лид, Telegram-алерты, Google Sheets, CRM, метрики.

## Файлы

| Файл | Назначение |
|---|---|
| `AI_Sales_Agent_Template_WebChat.json` | workflow n8n (76 узлов), готов к импорту |
| `seed_tenant_web.sql` | веб-тенант: `tenants` + `tenant_prompts` + `tenant_kb` (идемпотентно) |
| `README.md` | этот документ |

> Workflow в JSON — **самостоятельная копия** (`id = 7d0c3f3e130245b1`): при импорте создаётся
> новый workflow, существующие не перезаписываются. В файле `active: false` — после импорта
> его нужно опубликовать.

## HTTP-контракт

**POST** `https://<n8n-host>/webhook/ai-sales-agent-web`
(тест: `/webhook-test/ai-sales-agent-web`)

Заголовки: `Content-Type: application/json`; для проверки Origin — `Origin: https://client.example`.

```json
{
  "site_key": "demo-site-key",
  "session_id": "11111111-1111-4111-8111-111111111111",
  "message_id": "22222222-2222-4222-8222-222222222222",
  "text": "Здравствуйте! Расскажите про услуги и цены.",
  "page_url": "https://example.com/pricing"
}
```

| Ситуация | HTTP | Тело |
|---|---|---|
| Обычный ответ агента | 200 | `{"reply":"...","session_id":"..."}` |
| Ошибка/фолбэк | 200 | `{"reply":"...","error":true}` |
| Бот в ручном режиме / сообщение перекрыто | 200 | `{"reply":null,"muted":true}` |
| Пустой текст или нет `session_id` | 200 | `{"reply":null,"ignored":true}` |
| Повторный `message_id` | 200 | `{"reply":null,"duplicate":true}` |
| Origin не разрешён | 403 | `{"reply":"Чат недоступен на этом сайте.","error":true}` |
| Превышен `rate_limit_per_min` | 429 | `{"reply":"Слишком много сообщений...","error":true}` |

- `text` обрезается до 2000 символов; ответ AI валидируется и ограничен 4000.
- `session_id` чистится до `[A-Za-z0-9_-]`, максимум 64 символа; без него событие игнорируется.
- `message_id` — ключ дедупликации (`processed_messages.mid`), максимум 128 символов.
- `site_key` — публичный ключ сайта, лежит в `tenants.external_page_id` (`channel = 'web'`).
- `page_url` попадает в карточки менеджера и в уведомление о mute.

Виджет может присылать `message` вместо `text` и `mid` вместо `message_id` — `Normalize Events`
принимает оба варианта. Если `site_key` не передан, используется `DEFAULT_SITE_KEY` из
`Normalize Events` (по умолчанию `demo-site-key`) — удобно для односайтовых установок.

## Как устроен поток

```
Web Chat Webhook
  → Normalize Events            site_key/session_id/message_id/page_url → event
  → Ignore Event?               пустой текст/нет session_id → Log Ignored Event + Respond Empty
  → Resolve Tenant              дедуп по message_id + тенант по external_page_id (channel='web')
  → Tenant Found?
      ├─ нет (и нет page_id)   → Respond Duplicate
      └─ нет (tenant не найден) → Log Unknown Page + Respond Tenant Error
  → Guard                       allowed_origins + rate_limit_per_min из config тенанта
  → Guard OK?                   нет → Respond Blocked (403/429)
  → Load Context                дефолты + config, ключ памяти tenant:web:session
  → Mute Check / Is Muted?      да → Notify Muted + Respond Muted
  → Event Router (text)
  → Insert Pending → Restore Context → Debounce (Wait) → Is Last? / Has Newer?
      └─ перекрыто новым сообщением → Stop Superseded + Respond Silent
  → Claim Pending → Prepare Input → Load Lead → Merge Profile
  → Load Prompt → Load KB → Render Prompt → Prompt OK?
      └─ нет → Prompt Error → Format Error Alert + Respond Prompt Error
  → AI Agent (+ OpenRouter model, Postgres memory, structured output parser)
      └─ ошибка → AI Fallback → Format Error Alert + Respond AI Fallback
  → Validate Output → Output Valid?
      └─ нет → Invalid Output → Format Error Alert + Respond Invalid Fallback
  → Prepare Reply → Build Web Reply → Respond Chat   ← синхронный ответ клиенту
  → Build Summary → Save Lead → Handover?/Lead Alert? → Sheets → CRM → Insert Metrics
```

Ответ уходит в `Respond Chat`; запись лида, алерты, Sheets, CRM и метрики выполняются уже после
ответа клиенту.

## Настройки тенанта (`tenants.config`)

```json
{
  "business": { "name": "Demo", "languages": ["en", "ru"], "timezone": "Asia/Almaty" },
  "agent": { "model": "openai/gpt-4o-mini", "temperature": 0.3, "memory_window": 12 },
  "qualification": {
    "required_fields": [{ "key": "client_name", "label": "Имя" }],
    "handover_on_qualified": true
  },
  "integrations": { "telegram_enabled": true, "google_sheets_enabled": false, "crm_enabled": false },
  "notifications": {
    "telegram_chat_id": "123456789",
    "notify_on_qualified_lead": true,
    "notify_on_handover": true,
    "notify_on_error": true
  },
  "behavior": { "debounce_seconds": 0, "mute_hours": 48 },
  "allowed_origins": ["https://example.com"],
  "rate_limit_per_min": 20
}
```

- `agent.model` обязателен: пустая строка = ошибка OpenRouter и фолбэк клиенту.
- `allowed_origins` — белый список Origin. Пустой массив = разрешено всем; `*` тоже разрешает всем.
- `rate_limit_per_min` — лимит запросов в минуту на пару `tenant_id:session_id` (по умолчанию 20).
  Счётчики живут в static data workflow: работают только в опубликованном workflow и сбрасываются
  при рестарте n8n.
- `behavior.debounce_seconds`: `0` — отвечать сразу; `> 0` — ждать N секунд и склеивать сообщения
  (ответ задерживается).
- Если `telegram_enabled: false`, Telegram-узлы не вызываются; для error-пути нужен валидный
  credential либо `notify_on_error: false`.

### Язык бота

Язык ответа задают две вещи:

1. `business.languages` — список поддерживаемых языков. Первый элемент становится
   `language_default`, он же попадает в `{{languages}}` и в enum поля `lead_data.language`.
2. `tenant_prompts.system_prompt` — правило выбора языка. Без явной инструкции модель
   ориентируется на язык самого промпта и отвечает на нём всегда.

Варианты:

- только английский: `"languages": ["en"]` + правило «Always reply in English»;
- только русский: `"languages": ["ru"]` + «Всегда отвечай по-русски»;
- зеркалить язык клиента: `"languages": ["en", "ru"]` + «Reply in the same language as the
  customer's latest message».

Промпт хранится в `tenant_prompts` (одна активная версия). Меняется SQL-ом, а не через UI
workflow. После изменения промпта или конфига перепубликовывать workflow не нужно — он читает
их на каждом запросе.

## База данных

Workflow использует таблицы (см. `ai-sales-agent-template/database/schema.sql`):

`tenants`, `tenant_prompts`, `tenant_kb`, `leads`, `pending_messages`, `processed_messages`,
`sent_messages`, `metrics`, `error_log`, `ignored_events`, `unsupported_replies`,
`n8n_chat_histories` (память агента).

Требования:

- `tenants.channel = 'web'` — по этому полю ищется тенант; `external_page_id` = `site_key`.
- `channel` в `processed_messages`, `pending_messages`, `leads`, `metrics` принимает `'web'`
  (если есть CHECK только на `instagram` — расширьте).
- `metrics.ig_send_status` не переименовывался: 200 = ответ отдан; `chunks_count`/`send_attempts`
  для веб-чата всегда 1.
- `tenants.external_page_id` уникален: один `site_key` — один тенант.

### Несколько Telegram-чатов

`notifications.telegram_chat_ids` — массив чатов. Основные узлы шлют в `telegram_chat_id`
(первый чат), параллельные узлы `... 2` — в `telegram_chat_ids[1]`. Сейчас поддержано два чата.

Чтобы бот мог писать в чат, аккаунт должен сначала открыть бота и нажать **Start**
(иначе Telegram вернёт `Bad Request: chat not found`). Для группы нужен отрицательный chat_id
вида `-100...`, и бот должен быть добавлен в группу.

## Google Sheets

- Включение: `tenants.config.integrations.google_sheets_enabled = true`, `sheet_id`, `sheet_tab`.
  Включить сам узел `Save Sheet` и выбрать credential недостаточно — `Sheet Enabled?` смотрит
  на конфиг тенанта.
- Заголовки в первой строке: `tenant_id`, `customer_id`, `username`, `name`, `phone`, `service`,
  `city`, `status`, `summary`, `updated_at` (при записи в пустой лист n8n создаёт их сам).
- `matchingColumns` должен начинаться с `customer_id`: узел Google Sheets (v4.7) матчит только
  по первому столбцу из списка. Если первым стоит `tenant_id`, все сессии перезапишут одну строку.
- `Cell Format = RAW` в опциях `Save Sheet`, иначе телефон вида `+1 202 555 0147` Google
  воспримет как формулу и запишет `#ERROR!`.

## Заселение тенанта

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f seed_tenant_web.sql
```

Скрипт идемпотентен: повторный запуск обновляет конфиг, промпт и KB того же тенанта
(`ON CONFLICT`), а не создаёт дубликаты. Проверен на схеме из `ai-sales-agent-template`:
применяется на чистой БД и выполняется дважды без ошибок.

Перед запуском замените:

1. `demo-site-key` → ключ сайта (он же в виджете).
2. `PUT_TELEGRAM_CHAT_ID_HERE` → chat_id менеджера (или `telegram_enabled: false`).
3. `allowed_origins` → домены сайта.
4. `agent.model` → модель, доступную вашему ключу OpenRouter.

## Деплой на Railway (сервис `db-init`)

В репозитории есть `Dockerfile` + `db/init.sh` — одноразовый сервис, который применяет
`schema.sql` и (только на пустой базе) `seed_tenant_web.sql`, затем завершается.

1. В проекте Railway (например, `feisty-prosperity`, где уже есть n8n и Postgres) создайте
   сервис `db-init` из этого репозитория, ветка `main`.
2. Переменная сервиса: `DATABASE_URL = ${{Postgres.DATABASE_URL}}`.
3. Restart policy: `NEVER` (сервис должен отработать один раз и остановиться).
4. После деплоя в логах: `[db-init] schema ok` → `[db-init] done`.

Схема применяется в ту же базу, что использует n8n: таблицы проекта (`tenants`, `leads`,
`metrics` и т.д.) с внутренними таблицами n8n не пересекаются. Если нужна отдельная база —
создайте её и подставьте её URL в `DATABASE_URL`.

Повторный деплой безопасен: `schema.sql` идемпотентен, а seed пропускается, если в `tenants`
уже есть строки (демо-тенант не перезаписывается).

## Проверка

```bash
curl -sS --max-time 120 -X POST 'https://<n8n-host>/webhook/ai-sales-agent-web' \
  -H 'Content-Type: application/json' \
  -H 'Origin: https://example.com' \
  -d '{"site_key":"demo-site-key","session_id":"11111111-1111-4111-8111-111111111111","message_id":"'$(uuidgen)'","text":"Привет! Сколько стоит?","page_url":"https://example.com/"}' | jq
```

Ожидаемо: `{"reply":"...","session_id":"..."}`. В БД появятся строки в `processed_messages`,
`pending_messages`, `leads`, `metrics` с `channel = 'web'`.

Проверка дедупликации: повторите запрос с тем же `message_id` → `{"reply":null,"duplicate":true}`.

## Развёртывание

1. Импортировать `AI_Sales_Agent_Template_WebChat.json` — создастся отдельный workflow.
2. Проверить credentials: Postgres, OpenRouter, Telegram (Google Sheets отключён).
3. В `Web Chat Webhook` заменить `Allowed Origins (CORS)` = `*` на домены клиента.
4. Применить `seed_tenant_web.sql` и опубликовать workflow.
5. Проверить production URL из curl.

## Ограничения

- Принимается только текст: вложения и голос не поддерживаются.
- Ответ всегда один JSON, без стриминга и разбивки на чанки (лимит ответа 4000 символов).
- Rate limit хранится в static data одного инстанса: при нескольких репликах у каждой свой
  счётчик (дедупликация в БД при этом общая).
- `Respond Chat` отвечает до записи лида: ошибка в CRM/Sheets/метриках клиента уже не затронет.
