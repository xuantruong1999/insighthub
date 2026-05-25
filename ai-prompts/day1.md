# Day 1 — AI Prompt Log

> Workflow refactor InsightHub v0 → v1 (tách `ingestion-worker`, thêm Redis,
> chuyển upload sang async). Toàn bộ làm với Claude Code (Opus 4.7, 1M context).

---

## Prompt 1 — Đọc hiểu codebase + lập kế hoạch refactor

**Tool**: Claude Code (Opus 4.7)
**Time**: 2026-05-24 10:15

**Prompt** (Constraint-first 4-part):

```
[ROLE] Bạn là senior Python/DevOps engineer review codebase InsightHub.

[CONTEXT] Đọc các file sau:
  - api/app/services/ingestion.py
  - api/app/routers/documents.py
  - ingestion-worker/README.md
  - Running-Project-Specification-Student.md (section 5 — Day 1)

[CONSTRAINTS]
  - KHÔNG viết code, chỉ trình bày PLAN.
  - Tái sử dụng process_document() nguyên vẹn — không refactor logic chunk/embed.
  - Phải dùng ARQ (không Celery), psycopg3 (giữ nguyên), Redis 7.
  - process_document() phải idempotent vì ARQ retry.
  - Worker phải chạy trong cùng docker-compose, 5 service tổng.

[TASK] List ra theo thứ tự:
  1) Các file cần TẠO mới (path đầy đủ).
  2) Các file cần SỬA (path + 1 dòng tóm tắt diff).
  3) Risks / pitfalls cụ thể của bước này.
  Dừng lại và đợi tôi approve trước khi viết code.
```

**Why it worked**:
- Constraint-first ép agent đọc context trước, không nhảy vào code.
- "Trình bày PLAN trước" tạo review gate — tôi catch được early rằng
  agent định viết lại `process_document()` (vi phạm constraint).
- Cite spec file giúp agent biết MH1-MH11 cần đạt.

**What I changed**:
- PLAN ban đầu thiếu bước thêm `DELETE FROM chunks WHERE document_id` cho
  idempotency. Tôi yêu cầu bổ sung trước khi approve.
- PLAN gợi ý copy toàn bộ `api/` vào worker image — tôi reject, đề nghị
  chỉ COPY `api/app` để giảm layer size.

---

## Prompt 2 — Sinh code worker + Dockerfile share base

**Tool**: Claude Code (Opus 4.7)
**Time**: 2026-05-24 10:42

**Prompt**:

```
[CONTEXT] PLAN đã approve ở prompt #1. Giờ implement.

[CONSTRAINTS]
  - Worker import `from app.services.ingestion import process_document` —
    KHÔNG copy/paste logic.
  - process_document() là sync → bọc asyncio.run_in_executor trong task.
  - WorkerSettings: max_tries=3, job_timeout=300, max_jobs=4.
  - Dockerfile context = project root (vì copy cả api/app và ingestion-worker/).
  - PYTHONPATH=/app để import `app.*` và `worker.*` cùng namespace.
  - requirements.txt chỉ chứa deps worker thực sự cần (không kéo fastapi/uvicorn).

[TASK] Tạo các file:
  - ingestion-worker/worker/__init__.py
  - ingestion-worker/worker/tasks.py
  - ingestion-worker/worker/settings.py
  - ingestion-worker/requirements.txt
  - ingestion-worker/Dockerfile
Sau đó dừng lại cho tôi review trước khi sửa docker-compose.yml.
```

**Why it worked**:
- Chia nhỏ — chỉ làm worker, chưa đụng compose/api → review diff nhỏ, dễ catch lỗi.
- Constraint `PYTHONPATH=/app` chống được lỗi `ModuleNotFoundError: app.services`
  mà agent hay mắc khi copy nguyên `api/` thay vì `api/app/`.
- Cite max_tries/job_timeout cụ thể → không phải tranh luận default ARQ.

**What I changed**:
- Agent dùng `run_in_executor(None, process_document, *args)` — chuẩn.
- Quên `keep_result=3600` cho debug, tôi thêm tay.
- `CMD ["arq", "worker.settings.WorkerSettings"]` — agent gõ đúng module path
  ngay lần đầu nhờ constraint PYTHONPATH.

---

## Prompt 3 — Sửa API enqueue + compose 5 service + idempotency

**Tool**: Claude Code (Opus 4.7)
**Time**: 2026-05-24 11:08

**Prompt**:

```
[CONTEXT] Worker đã build. Giờ wire API enqueue + compose.

[CONSTRAINTS]
  - `POST /documents` đổi 201 → 202. Body chỉ trả {id, filename, status:"pending"}.
  - KHÔNG tạo arq pool mỗi request — share qua app.state.arq_pool, tạo 1 lần
    trong lifespan (theo pattern FastAPI 0.110+).
  - Thêm endpoint GET /documents/{id}/status để verify script poll được.
  - Trong `api/app/services/ingestion.py::process_document`, thêm
    `DELETE FROM chunks WHERE document_id = %s` đầu transaction → idempotent.
  - docker-compose.yml: thêm service redis (7-alpine, healthcheck) +
    ingestion-worker (build context: ., dockerfile: ingestion-worker/Dockerfile).
  - api service: thêm REDIS_URL=redis://redis:6379 + depends_on redis healthy.

[TASK] Output diff theo từng file, không tự apply. Tôi sẽ review rồi mới Edit.
```

**Why it worked**:
- "Output diff, không apply" cho phép tôi check kỹ trước khi commit — đặc biệt
  với compose vì sai 1 indent là cả stack chết.
- Cite pattern `app.state.arq_pool + lifespan` chặn agent recreate pool mỗi
  request (anti-pattern hay gặp trong tutorial cũ).
- Yêu cầu DELETE-before-INSERT cho idempotency rõ ràng → không phải debug
  duplicate chunks về sau khi ARQ retry.

**What I changed**:
- Diff đầu của agent quên `await app.state.arq_pool.close()` trong shutdown
  của lifespan → tôi thêm vào, tránh leak connection.
- Healthcheck `redis-cli ping` agent đề xuất `interval: 5s` — tôi giảm load
  thành 10s (verify script chỉ cần biết redis up, không cần aggressive).

---

## Tổng kết

- **Pattern thành công**: Constraint-first + PLAN-before-CODE + diff-before-apply.
- **Cost**: ~$0.42 cho cả Day 1 (1 main session, 3 prompts chính + vài tool call).
- **Thời gian human-in-loop**: ~50 phút (đọc spec 10' + 3 review gate × ~12' + verify 10').
- **Bug duy nhất gặp**: lần đầu `docker compose build` fail vì Dockerfile context
  sai (đặt `context: ./ingestion-worker` thay vì `.`) → fix 1 dòng compose.
