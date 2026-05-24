#!/usr/bin/env bash
# InsightHub — Verify Day 1 artifact
# Chạy: bash scripts/verify-day-1.sh
# Mục đích: kiểm tra Day 1 refactor đã đạt yêu cầu Must-have spec.

set -u

API="http://localhost:8000"
PASS=0
FAIL=0

green(){ printf "\033[32m%s\033[0m\n" "$1"; }
red(){ printf "\033[31m%s\033[0m\n" "$1"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$1"; }

ok() { green "  [PASS] $1"; PASS=$((PASS+1)); }
ng() { red "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=========================================="
echo " InsightHub — Verify Day 1 (AI Refactor)"
echo "=========================================="
echo

# MH1-2: CLAUDE.md 6-section, ≤ 200 dòng
echo "[1] CLAUDE.md quality..."
if [ -f CLAUDE.md ]; then
  LINES=$(wc -l < CLAUDE.md)
  if [ "$LINES" -le 200 ]; then
    ok "CLAUDE.md $LINES dòng (≤ 200)"
  else
    ng "CLAUDE.md $LINES dòng — vượt 200 dòng (cô đọng lại)"
  fi
  # Check 6 sections (loose match)
  SEC_COUNT=$(grep -cE '^## ' CLAUDE.md || true)
  if [ "$SEC_COUNT" -ge 5 ]; then
    ok "CLAUDE.md có $SEC_COUNT section (≥5 — đủ 6-section template)"
  else
    ng "CLAUDE.md chỉ $SEC_COUNT section (cần 6: Architecture/Conventions/Commands/Constraints/Domain/References)"
  fi
else
  ng "CLAUDE.md không tồn tại"
fi

# MH3: ingestion-worker directory exists with files
echo "[2] ingestion-worker tách ra..."
if [ -d ingestion-worker ] && [ -f ingestion-worker/Dockerfile ]; then
  ok "ingestion-worker/Dockerfile tồn tại"
else
  ng "ingestion-worker/Dockerfile thiếu"
fi

if [ -f ingestion-worker/worker/tasks.py ] || [ -f ingestion-worker/worker.py ]; then
  ok "Worker source code tồn tại"
else
  ng "Worker source code thiếu (tasks.py hoặc worker.py)"
fi

# MH4: docker-compose 5 services
echo "[3] docker-compose 5 service..."
if [ -f docker-compose.yml ]; then
  # Use awk to extract services block
  SERVICES=$(awk '/^services:/{flag=1; next} /^[a-z]/{flag=0} flag && /^  [a-z]/{print $1}' docker-compose.yml | sed 's/://g' | sort -u)
  COUNT=$(echo "$SERVICES" | wc -l)
  if [ "$COUNT" -ge 5 ]; then
    ok "docker-compose có $COUNT service: $(echo $SERVICES | tr '\n' ' ')"
  else
    ng "docker-compose chỉ có $COUNT service (cần 5: web/api/ingestion-worker/redis/postgres)"
  fi
fi

# MH5-6: API trả 202 nhanh khi upload
echo "[4] API responsiveness..."
if curl -sf "$API/healthz" >/dev/null 2>&1; then
  ok "API alive"

  if [ -f sample-docs/so-tay-van-hanh.md ]; then
    # Measure upload time
    START=$(date +%s%N)
    HTTP_CODE=$(curl -s -o /tmp/upload.json -w "%{http_code}" -X POST "$API/documents" \
      -F "file=@sample-docs/so-tay-van-hanh.md" 2>/dev/null || echo "000")
    END=$(date +%s%N)
    ELAPSED_MS=$(( (END - START) / 1000000 ))

    if [ "$HTTP_CODE" = "202" ] && [ "$ELAPSED_MS" -lt 1000 ]; then
      ok "POST /documents → 202 trong ${ELAPSED_MS}ms (< 1s, async!)"
    elif [ "$HTTP_CODE" = "201" ]; then
      ng "POST /documents → 201 (v0 sync) — chưa refactor async"
    else
      ng "POST /documents → HTTP $HTTP_CODE trong ${ELAPSED_MS}ms"
    fi

    # Check status changes to ready async
    DOC_ID=$(cat /tmp/upload.json | python3 -c "import sys,json; print(json.load(sys.stdin).get('id', ''))" 2>/dev/null)
    if [ -n "$DOC_ID" ]; then
      echo "    Polling status of document $DOC_ID..."
      for i in 1 2 3 4 5 6; do
        sleep 5
        STATUS=$(curl -sf "$API/documents" | python3 -c "
import sys, json
docs = json.load(sys.stdin)
for d in docs:
    if d['id'] == int('$DOC_ID'):
        print(d['status'])
        break" 2>/dev/null)
        if [ "$STATUS" = "ready" ]; then
          ok "Document $DOC_ID → 'ready' sau ~$((i*5))s (worker xử lý xong)"
          break
        fi
      done
      [ "$STATUS" != "ready" ] && ng "Document $DOC_ID không chuyển 'ready' trong 30s (worker không hoạt động?)"
    fi
  fi
else
  ng "API không phản hồi $API/healthz — chạy 'docker compose up' trước"
fi

# MH8: Chat vẫn work
# NOTE: dùng heredoc + --data-binary để giữ UTF-8 nguyên vẹn
# (Git Bash trên Windows mangle UTF-8 khi truyền qua argv `-d`).
echo "[5] Chat API vẫn hoạt động..."
CHAT=$(curl -sf -X POST "$API/chat" -H "Content-Type: application/json" \
  --data-binary @- <<'JSON' 2>/dev/null
{"question":"InsightHub có mấy thành phần chính?"}
JSON
)
if echo "$CHAT" | grep -q '"answer"'; then
  ok "POST /chat trả về answer"
else
  ng "POST /chat lỗi"
fi

# MH11: ai-prompts/day1.md
echo "[6] AI prompt log..."
if [ -f ai-prompts/day1.md ]; then
  PROMPT_COUNT=$(grep -cE '^## Prompt' ai-prompts/day1.md || true)
  if [ "$PROMPT_COUNT" -ge 3 ]; then
    ok "ai-prompts/day1.md có $PROMPT_COUNT prompt (≥3)"
  else
    ng "ai-prompts/day1.md chỉ có $PROMPT_COUNT prompt (cần ≥3)"
  fi
else
  ng "ai-prompts/day1.md không tồn tại"
fi

# Bonus: pytest
echo "[7] Tests pass..."
if command -v pytest >/dev/null 2>&1 && [ -d api/tests ]; then
  if (cd api && pytest -q --tb=no 2>&1 | grep -q "passed"); then
    ok "pytest pass"
  else
    yellow "  [WARN] pytest có failure (kiểm tra trước commit)"
  fi
else
  yellow "  [SKIP] pytest không available hoặc không có tests/"
fi

echo
echo "=========================================="
echo " Kết quả: $PASS PASS / $FAIL FAIL"
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  green "✅ Day 1 artifacts đạt yêu cầu Must-have. Submit qua Slack #day1-submissions."
else
  red "❌ Còn $FAIL FAIL. Fix theo Day1-Spec.md trước khi submit."
  exit 1
fi
