#!/bin/bash
# Request log (WS-B.4): one JSON line per answered question -> /var/log/autohub/requests.log,
# shipped by the CloudWatch agent to /autohub/app (stream <instance>-requests).
# Fields: ts, question (invented customer text, first 200 chars), ok, duration_ms, model, build, conversation.
# Runs after every health check (every 5 min). Usage: request-log.sh [since-ISO-time]  (backfill)
source /opt/autohub/ops/autohub.conf
STATE=/var/lib/autohub/requests.since
OUT=/var/log/autohub/requests.log
mkdir -p /var/lib/autohub /var/log/autohub
NOW=$(date -u +%FT%T.000Z)
SINCE=${1:-$(cat "$STATE" 2>/dev/null || date -u -d '-10 min' +%FT%T.000Z)}
BUILD=$(git -C /opt/autohub/LibreChat rev-parse --short HEAD 2>/dev/null || echo unknown)

docker exec chat-mongodb mongosh --quiet LibreChat --eval "
const since = new Date('$SINCE'), until = new Date('$NOW');
db.messages.find({isCreatedByUser: false, createdAt: {\$gt: since, \$lte: until}}).sort({createdAt: 1}).forEach(a => {
  const q = db.messages.findOne({messageId: a.parentMessageId});
  const end = a.updatedAt || a.createdAt;
  // newer LibreChat keeps the answer in content[] parts; older in text
  const parts = (a.content || []).filter(p => p && p.type === 'text')
                 .map(p => typeof p.text === 'string' ? p.text : ((p.text && p.text.value) || ''));
  const text = (a.text || '') + parts.join('');
  print(JSON.stringify({
    ts: end.toISOString(),
    question: q ? (q.text || '').slice(0, 200) : '',
    ok: !a.error && text.length > 0 && !/could not complete this request/i.test(text),
    answer_chars: text.length,
    duration_ms: q ? (end - q.createdAt) : null,
    model: a.model || '', build: '$BUILD', conversation: a.conversationId
  }));
});" >> "$OUT" && echo "$NOW" > "$STATE"
