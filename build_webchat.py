#!/usr/bin/env python3
"""Rebuild the n8n AI Sales Agent workflow for a website chat widget (HTTP webhook)."""
import json
import re
import uuid
import copy
from pathlib import Path

SRC = Path('/tmp/opencode/uploads/aec05db5-f63c-493e-ab9f-d7013c3b05c1/AI Sales Agent Template (Multi-Tenant) (4).json')
DST = Path(__file__).with_name('AI_Sales_Agent_Template_WebChat.json')

wf = json.loads(SRC.read_text(encoding='utf-8'))
nodes = {n['name']: n for n in wf['nodes']}
conn = wf['connections']

def new_id():
    return str(uuid.uuid4())

def touch(name, **updates):
    """Apply shallow updates to a node's top-level fields (parameters handled separately)."""
    n = nodes[name]
    for k, v in updates.items():
        n[k] = v
    return n

# ---------------------------------------------------------------------------
# 1. Delete the Meta branch + Instagram transport nodes
# ---------------------------------------------------------------------------
DELETED = [
    'Meta Webhook', 'Is POST?', 'Verify HMAC', 'Signature Valid?', 'Respond 200',
    'Respond 403 Signature', 'Verify Challenge', 'Challenge Valid?',
    'Respond Challenge', 'Respond 403 Challenge',
    'Split Chunks', 'Loop Chunks', 'Send to IG', 'Send Error',
    'Send Invalid Fallback', 'Send AI Fallback', 'Send Fallback',
    'Send Unsupported', 'Fetch Profile',
]

def drop_refs(name):
    for outs in conn.values():
        for branches in outs.values():
            for branch in branches:
                branch[:] = [c for c in branch if c.get('node') != name]
    conn.pop(name, None)

for name in DELETED:
    nodes.pop(name, None)
    drop_refs(name)

def main(branches):
    """Build a connections entry from {output_index: [target names]}."""
    out = []
    for i in sorted(branches):
        out.append([{'node': t, 'type': 'main', 'index': 0} for t in branches[i]])
    return {'main': out}

# ---------------------------------------------------------------------------
# 2. New / replaced nodes
# ---------------------------------------------------------------------------

def respond_node(name, position, body_expr, notes):
    return {
        'parameters': {
            'respondWith': 'json',
            'responseBody': '={{ ' + body_expr + ' }}',
            'options': {},
        },
        'id': new_id(),
        'name': name,
        'type': 'n8n-nodes-base.respondToWebhook',
        'typeVersion': 1.5,
        'position': position,
        'notes': notes,
    }

def code_node(name, position, js, notes):
    return {
        'parameters': {'jsCode': js},
        'id': new_id(),
        'name': name,
        'type': 'n8n-nodes-base.code',
        'typeVersion': 2,
        'position': position,
        'notes': notes,
    }

webhook = {
    'parameters': {
        'httpMethod': 'POST',
        'path': 'ai-sales-agent-web',
        'responseMode': 'responseNode',
        'options': {
            'allowedOrigins': '*',
        },
    },
    'id': new_id(),
    'name': 'Web Chat Webhook',
    'type': 'n8n-nodes-base.webhook',
    'typeVersion': 2.1,
    'position': [0, 304],
    'webhookId': new_id(),
    'notes': ('Вход веб-чата: POST JSON от виджета. CORS * — ЗАМЕНИТЬ на домены клиента. '
              'Ответ синхронный через Respond to Webhook.'),
}

build_web_reply = code_node(
    'Build Web Reply', [7712, 400],
    """const ctx = $input.first().json ?? {};
const reply = String(ctx.reply ?? '').trim();
const sessionId = String(ctx.customer_id ?? ctx.event?.sender_id ?? '');
const outId = String(ctx.mid || (Date.now() + '-' + Math.random().toString(36).slice(2))) + ':out';
return [{ json: {
  ...ctx,
  web_reply: reply,
  session_id: sessionId,
  message_id: outId,
  response_body: JSON.stringify({ reply, session_id: sessionId })
} }];""",
    'Единый ответ веб-чату: склеенные чанки не нужны, отдаём полный текст одним JSON.',
)

respond_chat = respond_node(
    'Respond Chat', [7920, 400],
    '$json.response_body',
    'Синхронный ответ виджета: { reply, session_id }.',
)
respond_muted = respond_node(
    'Respond Muted', [3312, 304],
    'JSON.stringify({ reply: null, muted: true })',
    'Режим «бот молчит»: пустой reply + muted.',
)
respond_silent = respond_node(
    'Respond Silent', [4400, 176],
    'JSON.stringify({ reply: null, muted: true })',
    'Сообщение перекрыто более новым (debounce): тихий ответ, запрос не висит.',
)
respond_empty = respond_node(
    'Respond Empty', [1552, 192],
    'JSON.stringify({ reply: null, muted: true })',
    'Пустое/служебное событие: тихий ответ, чтобы виджет не ждал таймаут.',
)
respond_tenant_error = respond_node(
    'Respond Tenant Error', [1984, 736],
    "JSON.stringify({ reply: 'Чат временно недоступен. Обновите страницу и попробуйте ещё раз.', error: true })",
    'Неизвестный site_key или дубль message_id: ошибка клиенту.',
)
respond_prompt_error = respond_node(
    'Respond Prompt Error', [6608, 688],
    "JSON.stringify({ reply: $json.config?.behavior?.ai_error_fallback_text || 'Извините, сейчас не могу ответить. Передам сообщение менеджеру.', error: true })",
    'Промпт/KB не готовы: клиент получает fallback, админ — алерт.',
)
respond_invalid = respond_node(
    'Respond Invalid Fallback', [7712, 544],
    "JSON.stringify({ reply: $json.fallback_text || 'Извините, сейчас не могу ответить.', error: true })",
    'Невалидный вывод агента: fallback клиенту.',
)
respond_ai_fallback = respond_node(
    'Respond AI Fallback', [7040, 608],
    "JSON.stringify({ reply: $json.fallback_text || 'Извините, сейчас не могу ответить.', error: true })",
    'Сбой AI: fallback клиенту.',
)
respond_voice_fallback = respond_node(
    'Respond Fallback', [3968, 768],
    "JSON.stringify({ reply: $json.fallback_text || 'Напишите, пожалуйста, текстом.', error: true })",
    'Сбой аудио: fallback клиенту (ветка недоступна для веб-чата).',
)
respond_unsupported = respond_node(
    'Respond Unsupported', [3744, 688],
    "JSON.stringify({ reply: $('Load Context').first().json.config.behavior.unsupported_reply_text, error: true })",
    'Неподдерживаемое вложение: вежливый отказ (ветка недостижима без attachments).',
)

for n in (webhook, build_web_reply, respond_chat, respond_muted, respond_silent,
          respond_empty, respond_tenant_error, respond_prompt_error, respond_invalid,
          respond_ai_fallback, respond_voice_fallback, respond_unsupported):
    assert n['name'] not in nodes, n['name']
    nodes[n['name']] = n

wf['nodes'] = list(nodes.values())

# ---------------------------------------------------------------------------
# 3. Normalize Events: new web-chat normalizer (exact code from the task)
# ---------------------------------------------------------------------------
nodes['Normalize Events']['parameters']['jsCode'] = """const b = $json.body ?? {};
const text = String(b.text ?? '').trim().slice(0, 2000);
const event = {
  page_id: String(b.site_key ?? ''),
  channel: 'web',
  sender_id: String(b.session_id ?? '').slice(0, 64),
  recipient_id: '',
  mid: String(b.message_id || (Date.now() + '-' + Math.random().toString(36).slice(2))),
  text,
  attachments: [],
  reply_to: null,
  page_url: String(b.page_url ?? '').slice(0, 500),
  timestamp: Date.now(),
  event_kind: text ? 'message' : 'unknown'
};
event.event_b64 = Buffer.from(JSON.stringify(event), 'utf8').toString('base64');
return [{ json: event }];
"""
nodes['Normalize Events']['notes'] = 'Один HTTP-запрос = одно событие веб-чата; site_key → page_id, session_id → sender_id.'

# ---------------------------------------------------------------------------
# 4. Tenant resolution: channel instagram -> web
# ---------------------------------------------------------------------------
rt = nodes['Resolve Tenant']
rt['parameters']['query'] = rt['parameters']['query'].replace("'instagram'", "'web'")
rt['notes'] = 'Дедуп по message_id + поиск tenant по site_key (tenants.external_page_id, channel=web).'

# ---------------------------------------------------------------------------
# 5. Load Context: channel + memory key
# ---------------------------------------------------------------------------
lc = nodes['Load Context']
lc['parameters']['jsCode'] = lc['parameters']['jsCode'].replace(
    "const event = j.event ?? {};\nconst text = String(event.text ?? '');",
    "const event = j.event ?? {};\nconst text = String(event.text ?? '');\nconst channel = String(event.channel ?? 'web');",
).replace(
    "channel: String(event.channel ?? 'instagram'),",
    "channel,",
).replace(
    "memory_key: String(j.tenant_id) + ':instagram:' + String(event.sender_id ?? ''),",
    "memory_key: String(j.tenant_id) + ':' + channel + ':' + String(event.sender_id ?? ''),",
)
lc['notes'] = 'Мерж tenant-конфига с дефолтами, ключ памяти tenant:channel:session.'

# ---------------------------------------------------------------------------
# 6. Manager-facing cards: replace Instagram links with page_url
# ---------------------------------------------------------------------------
nm = nodes['Notify Muted']
nm['parameters']['text'] = nm['parameters']['text'].replace(
    'https://instagram.com/direct/t/{{ $json.customer_id }}',
    "{{ $json.event?.page_url || 'веб-чат' }}",
)
nm['parameters']['text'] = nm['parameters']['text'].replace('👤 Клиент:', '🌐 Страница:')

for card in ('Build Handover', 'Build Lead Card'):
    src = nodes[card]['parameters']['jsCode']
    src = src.replace(
        "const profile = s.username ? 'https://instagram.com/' + esc(s.username) : ('https://instagram.com/direct/t/' + esc(s.customer_id));",
        "const profile = esc(s.event?.page_url || s.page_url || '—');",
    )
    assert 'instagram.com' not in src, card
    nodes[card]['parameters']['jsCode'] = src

# ---------------------------------------------------------------------------
# 7. Build Summary: delivery accounting no longer relies on the IG sender
# ---------------------------------------------------------------------------
bs = nodes['Build Summary']
bs['parameters']['jsCode'] = bs['parameters']['jsCode'].replace(
    "const attempts = safeAll('Send to IG');",
    'const attempts = sent;',
)
bs['notes'] = 'Сводка: фактическая доставка (запись sent_messages), а не «200 по умолчанию».'

nodes['Has Profile?']['notes'] = 'Для веб-чата профиль Graph не нужен: обе ветки идут в Merge Profile.'
nodes['Log Sent']['notes'] = 'Пишем исходящее сообщение (mid:out) в sent_messages — совместимость и метрики.'

# ---------------------------------------------------------------------------
# 8. Rebuild the affected connections
# ---------------------------------------------------------------------------
conn['Web Chat Webhook'] = main({0: ['Normalize Events']})

conn['Prepare Reply'] = main({0: ['Build Web Reply']})
conn['Build Web Reply'] = main({0: ['Respond Chat']})
conn['Respond Chat'] = main({0: ['Log Sent']})
conn['Log Sent'] = main({0: ['Build Summary']})

conn['Has Profile?'] = main({0: ['Merge Profile'], 1: ['Merge Profile']})

conn['Invalid Output'] = main({0: ['Respond Invalid Fallback', 'Format Error Alert']})
conn['AI Fallback'] = main({0: ['Respond AI Fallback', 'Format Error Alert']})
conn['Voice Fallback'] = main({0: ['Respond Fallback', 'Format Error Alert']})
conn['Prompt Error'] = main({0: ['Respond Prompt Error', 'Format Error Alert']})

conn['Media Allowed?'] = main({0: ['Respond Unsupported']})
conn['Respond Unsupported'] = main({0: ['Record Media']})

conn['Log Ignored Event'] = main({0: ['Respond Empty']})
conn['Log Unknown Page'] = main({0: ['Respond Tenant Error']})
conn['Notify Muted'] = main({0: ['Respond Muted']})
conn['Stop Superseded'] = main({0: ['Respond Silent']})

# ---------------------------------------------------------------------------
# 9. pinData for the new trigger (old Meta sample is meaningless/invalid)
# ---------------------------------------------------------------------------
wf['name'] = 'AI Sales Agent Template (Multi-Tenant) — Web Chat'
wf['id'] = 'wcWebChatA7Lm4Tz1'
wf['versionId'] = str(uuid.uuid4())

wf['pinData'] = {
    'Web Chat Webhook': [{
        'json': {
            'headers': {'content-type': 'application/json'},
            'params': {},
            'query': {},
            'body': {
                'site_key': 'demo-site-key',
                'session_id': '11111111-1111-4111-8111-111111111111',
                'message_id': '22222222-2222-4222-8222-222222222222',
                'text': 'Здравствуйте! Расскажите про услуги и цены.',
                'page_url': 'https://example.com/pricing',
            },
            'webhookUrl': 'https://YOUR-N8N-HOST/webhook/ai-sales-agent-web',
            'executionMode': 'production',
        },
    }],
}

# trigger first, keep the rest of the original order
wf['nodes'] = sorted(wf['nodes'], key=lambda n: 0 if n['name'] == 'Web Chat Webhook' else 1)

# ---------------------------------------------------------------------------
# 10. Validation
# ---------------------------------------------------------------------------
names = {n['name'] for n in wf['nodes']}
ids = [n['id'] for n in wf['nodes']]
assert len(ids) == len(set(ids)), 'duplicate node ids'

errors = []
for src_name, outs in conn.items():
    if src_name not in names:
        errors.append(f'connection source missing: {src_name}')
    for branches in outs.values():
        for branch in branches:
            for c in branch:
                if c['node'] not in names:
                    errors.append(f'{src_name} -> missing {c["node"]}')

ref_re = re.compile(r"\$\(\s*'([^']+)'\s*\)")
for n in wf['nodes']:
    blob = json.dumps(n, ensure_ascii=False)
    for ref in ref_re.findall(blob):
        if ref not in names:
            errors.append(f'{n["name"]} references missing node {ref}')

assert not errors, '\n'.join(errors)

# every node should be reachable from the trigger
incoming = {c['node'] for outs in conn.values() for br in outs.values() for b in br for c in b}
unreachable = sorted(names - incoming - {'Web Chat Webhook'})
print('nodes:', len(wf['nodes']))
print('unreachable:', unreachable)
print('remaining instagram mentions:',
      sum(json.dumps(n, ensure_ascii=False).count('instagram') for n in wf['nodes']))

DST.write_text(json.dumps(wf, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('written:', DST)
