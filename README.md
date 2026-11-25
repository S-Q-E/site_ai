# AI Sales Agent — веб-чат вместо Instagram DM

Копия workflow `AI Sales Agent Template (Multi-Tenant)` с входом от виджета чата на сайте
и синхронным ответом через **Respond to Webhook**.

| Файл | Что это |
|---|---|
| `AI_Sales_Agent_Template_WebChat.json` | Готовый к импорту workflow (валидный JSON, 88 узлов) |
| `build_webchat.py` | Скрипт, которым собрана копия (исходник не изменялся) |
| `README.md` | Этот отчёт |

Исходный файл `AI Sales Agent Template (Multi-Tenant) (4).json` не изменялся.

---

## 1. Контракт

**POST** `https://<n8n-host>/webhook/ai-sales-agent-web`
(тестовый: `https://<n8n-host>/webhook-test/ai-sales-agent-web`)

Запрос (`Content-Type: application/json`, обязателен — иначе n8n не распарсит `body`):

```json
{
  "site_key": "demo-site-key",
  "session_id": "11111111-1111-4111-8111-111111111111",
  "message_id": "22222222-2222-4222-8222-222222222222",
  "text": "Здравствуйте! Расскажите про услуги и цены.",
  "page_url": "https://example.com/pricing"
}
```

Ответ — всегда JSON, ровно один из трёх видов:

```json
{ "reply": "текст", "session_id": "..." }
{ "reply": "текст", "error": true }
{ "reply": null, "muted": true }
```

- `text` обрезается до 2000 символов, пустой текст считается служебным событием.
- `message_id` — ключ дедупликации (`processed_messages.mid`). Повторный запрос с тем же
  `message_id` не обрабатывается повторно (см. п. 6).
- `session_id` — ключ диалога (память, лид, метрики). Хранится в localStorage браузера.

Проверка:

```bash
curl -sS -X POST 'https://<n8n-host>/webhook/ai-sales-agent-web' \
  -H 'Content-Type: application/json' \
  -H 'Origin: https://example.com' \
  -d '{"site_key":"demo-site-key","session_id":"11111111-1111-4111-8111-111111111111","message_id":"'$(uuidgen)'","text":"Привет! Сколько стоит?","page_url":"https://example.com/"}' | jq
```

## 2. Маппинг полей

| Instagram | Веб-чат | Где |
|---|---|---|
| `page_id` | `site_key` (публичный ключ сайта, лежит в `tenants.external_page_id`) | `Normalize Events` → `page_id` |
| `sender_id` | `session_id` (UUID из localStorage) | `Normalize Events` → `sender_id`, далее `customer_id` |
| `mid` | `message_id` (UUID от виджета) | `Normalize Events` → `mid` |
| `channel: 'instagram'` | `channel: 'web'` | `Normalize Events`, `Resolve Tenant`, `Load Context` |
| `page_url` | новый атрибут события | `Normalize Events` → `page_url` (в карточках менеджера) |

## 3. Что изменено в узлах

### Вход
- **Удалена вся Meta-ветка**: `Meta Webhook`, `Is POST?`, `Verify HMAC`, `Signature Valid?`,
  `Respond 200`, `Respond 403 Signature`, `Verify Challenge`, `Challenge Valid?`,
  `Respond Challenge`, `Respond 403 Challenge`.
- **Новый** `Web Chat Webhook` (id/`webhookId` новые, позиция `[0, 304]` — на месте старого):
  `httpMethod: POST`, `path: ai-sales-agent-web`, `responseMode: responseNode`,
  `options.allowedOrigins: "*"`. Параметра `multipleMethods` нет.
- Вход соединён напрямую: `Web Chat Webhook → Normalize Events`. Ранний ответ 200 не нужен.
- `pinData` заменён на веб-пример (старый Instagram-сэмпл удалён).

> ⚠️ **CORS**: в узле стоит `*`. Перед продакшеном замените на домены клиента,
> например `https://client.ru,https://www.client.ru` (поле *Allowed Origins (CORS)*).
> n8n сам отвечает на preflight `OPTIONS`.

### Нормализация
- `Normalize Events` — `jsCode` заменён целиком на присланный вариант (`channel: 'web'`,
  `attachments: []`, `event_kind` = `message`/`unknown`, `event_b64` для дедупликации).

### Тенанты / контекст / память
- `Resolve Tenant` — в SQL `'instagram'` → `'web'` в `processed_messages` и в join
  `tenants.channel = 'web'`. Остальной SQL (дедуп + выборка tenant по `external_page_id`) не тронут.
- `Load Context` — `channel` берётся из события (fallback `'web'`), `memory_key` теперь
  `tenant_id:web:session_id` (раньше жёстко `:instagram:`).
- `Has Profile?` — обе ветки ведут в `Merge Profile`; узел `Fetch Profile` (запрос Graph API
  за профилем Instagram) удалён, т.к. для веб-чата профиля нет.
- `Notify Muted`, `Build Handover`, `Build Lead Card` — ссылки `instagram.com/direct/t/...`
  заменены на `page_url` из запроса.

### Ответ клиенту
- `Prepare Reply` оставлен без изменений (он же считает `chunks_count` для метрик).
- **Новый** `Build Web Reply` (на месте `Split Chunks`): собирает один ответ, кладёт
  `response_body = {"reply","session_id"}` и синтетический `message_id = <mid>:out`.
- **Новый** `Respond Chat` (на месте `Loop Chunks`): `respondWith: json`, тело —
  `response_body`. Ответ уходит синхронно, затем выполнение продолжается
  (`Log Sent → Build Summary → лид → Telegram → Sheets → CRM → метрики`).
- Удалены ставшие ненужными `Split Chunks`, `Loop Chunks`, `Send to IG`, `Send Error`
  (чанкинг на 950 символов для одного HTTP-ответа не нужен; ответ валидируется до 4000 симв.).
- `Log Sent` не тронут: получает `message_id` из `Build Web Reply`, пишет в `sent_messages`.
- `Build Summary` — `send_attempts` теперь считается по записи `Log Sent` (раньше — по
  `Send to IG`). Имена полей `ig_send_status`, `chunks_sent` сохранены ради схемы БД.
- Ответы на остальных ветках (все — `respondToWebhook`, новые id, позиции на месте старых
  HTTP-узлов):
  - `Respond Invalid Fallback` ← `Invalid Output` — `{reply, error:true}`;
  - `Respond AI Fallback` ← `AI Fallback` — `{reply, error:true}`;
  - `Respond Fallback` ← `Voice Fallback` — `{reply, error:true}`;
  - `Respond Unsupported` ← `Media Allowed?` — `{reply, error:true}`;
  - `Respond Prompt Error` ← `Prompt Error` — `{reply, error:true}`;
  - `Respond Tenant Error` ← `Log Unknown Page` — `{reply, error:true}`;
  - `Respond Muted` ← `Notify Muted` — `{reply:null, muted:true}`;
  - `Respond Silent` ← `Stop Superseded` — `{reply:null, muted:true}` (сообщение перекрыто более новым);
  - `Respond Empty` ← `Log Ignored Event` — `{reply:null, muted:true}` (пустой/служебный текст).

Никаких обращений к Graph API Instagram в workflow не осталось.

### Что не тронуто
ID, credentials, позиции, `typeVersion` и параметры всех остальных узлов сохранены:
дедупликация/debounce (`Insert Pending`, `Wait Debounce`, `Is Last?`, `Has Newer?`,
`Claim Pending`), `Load Lead`, промпт (`Load Prompt`, `Load KB`, `Render Prompt`, `Prompt OK?`),
AI Agent + модель + память + output parser, `Validate Output`, сохранение лида, handover,
Telegram-алерты, Google Sheets, CRM, метрики, логирование ошибок.
Ветки audio/media/echo оставлены как есть — для веб-чата они недостижимы
(`attachments: []`, эхо-событий нет), но не мешают.

## 4. Обязательные шаги после импорта

1. Открыть workflow, проверить credentials: **Postgres**, **OpenRouter**, **Telegram**
   (Google Sheets выключен). Новый webhook креденшелов не требует.
2. Заменить `Allowed Origins (CORS)` = `*` на домены клиента.
3. Включить (Activate) workflow — production URL появится только после публикации.
4. Зарегистрировать сайт в БД (пример; имена колонок — по текущей схеме):

```sql
-- новый веб-тенант; site_key — публичный, не секрет
INSERT INTO tenants (channel, external_page_id, config, is_active)
VALUES ('web', 'demo-site-key', '{"business":{"name":"Demo"}}'::jsonb, true);

-- либо миграция существующего тенанта на веб-канал
UPDATE tenants
SET channel = 'web', external_page_id = 'demo-site-key'
WHERE tenant_id = '<tenant_id>';
```

## 5. Допущения по БД (не выдумывал схему — проверьте)

1. **`tenants.channel = 'web'`** — `Resolve Tenant` ищет тенанта по
   `external_page_id = site_key AND channel = 'web' AND is_active = true`.
   Если у вас веб-тенанты помечены иначе, поменяйте литерал `'web'` в SQL `Resolve Tenant`
   (два места: `processed_messages` и join).
2. `processed_messages.channel`, `pending_messages.channel`, `leads.channel`,
   `metrics.channel`, `unsupported_replies.channel` — текстовые, принимают `'web'`.
   Если есть `CHECK (channel IN ('instagram'))` — расширьте ограничение.
3. `leads.customer_id` = `session_id` (UUID браузера), уникальность —
   `(tenant_id, channel, customer_id)`, как и раньше.
4. `sent_messages.external_message_id` принимает строку `<message_id>:out`
   (для UUID-сообщения — 40 символов). Если колонка короче — увеличьте длину.
5. `ignored_events.page_id` по-прежнему хранит `site_key` (семантика колонки расширена).
6. `metrics.ig_send_status` не переименовывался: 200 = ответ отдан, 0 = нет.
   `metrics.chunks_count` = число чанков подготовленного ответа (для веб обычно 1).

## 6. Поведение и ограничения

- **Синхронность**: HTTP-ответ отправляется в `Respond Chat`; запись лида, Sheets, CRM и
  метрики выполняются уже после ответа. Ошибка в этих узлах клиента не затрагивает.
- **Debounce** (tenant-конфиг `behavior.debounce_seconds`, по умолчанию 5 с) выполняется
  до ответа: ответ придёт примерно через 5 с + время AI. Для веб-чата разумно поставить
  `0` в конфиге тенанта, иначе запрос держится открытым.
- **Таймауты**: n8n Cloud/Cloudflare рвёт запрос через 100 с; reverse-proxy может рвать
  раньше. Долгий AI-ответ или `Wait Debounce` могут не уложиться — тогда виджет получит
  сетевую ошибку, хотя лид сохранится. При необходимости уменьшите debounce/модель.
- **Молчание**: `muted:true` возвращается, когда бот в ручном режиме (`Is Muted?`),
  когда сообщение перекрыто более новым (debounce) и когда текст пустой. Виджет должен
  трактовать это как «ответа не будет» и не показывать ошибку.
- **Дубликат `message_id`**: `Resolve Tenant` не возвращает строку, срабатывает
  `Tenant Found? → false → Log Unknown Page → Respond Tenant Error`. Клиент получает
  `{reply, error:true}`, повторная обработка не запускается. Это осознанное поведение
  дедупликации; при ретраях после успешного ответа виджет увидит ошибку.
- **Неизвестный `site_key`** даёт тот же `{reply, error:true}` — проверяйте ключ в виджете.
- **Вложения** веб-чатом не поддерживаются (`attachments: []`); ветки audio/media
  технически недостижимы, но на всякий случай отвечают `error:true`.
- Ответ AI валидируется и ограничен 4000 символами, входящий текст — 2000.
- Аутентификации/HMAC у вебхука нет: `site_key` — публичный идентификатор, не секрет.
  Для продакшена желательны rate limit на прокси и CORS только на домены клиента.

## 7. Быстрая проверка после импорта

1. Import → открыть `Web Chat Webhook` → скопировать Test URL.
2. «Listen for test event» → отправить curl выше.
3. Ожидаемо: `Normalize Events` даёт `channel: "web"`, `Resolve Tenant` находит тенанта,
   `Respond Chat` возвращает `{"reply":"...","session_id":"..."}`.
4. В БД: строка в `processed_messages`, `pending_messages` (обработана), `leads`,
   `sent_messages`, `metrics` с `channel = 'web'`.
5. Проверить mute: выставить `leads.muted_until` в будущее → ответ `{"reply":null,"muted":true}`.
6. Проверить неизвестный ключ: `site_key: "nope"` → `{"reply":"...","error":true}`.
