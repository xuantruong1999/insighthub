#!/usr/bin/env bash
# Sinh tải baseline cho anomaly detection. Cần port-forward svc/api 8000.
# Endpoint khớp router thật: POST /documents (upload), POST /chat (RAG query).
set -u
API="${API:-http://localhost:8000}"
DOC="${1:-sample-docs/service-level-objectives.md}"
echo "Loadgen → $API (Ctrl-C để dừng)"
while true; do
  curl -s -F "file=@${DOC}" "$API/documents" >/dev/null
  curl -s -X POST "$API/chat" -H 'Content-Type: application/json' \
    -d '{"question":"What is InsightHub?"}' >/dev/null
  sleep 10
done
