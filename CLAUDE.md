# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> InsightHub = RAG Notebook (upload docs → chunk + embed → chat). It is the
> running project for the 7-day AI-Native DevOps module. The app code is
> provided; the student "DevOps-izes" it day by day. Several directories are
> intentionally empty until the day they are needed — do not treat their
> absence as a bug.

## Architecture

**v0 (current state, 3 services):** `web` (Next.js 15) → `api` (FastAPI) → `postgres` (pgvector). Ingestion runs **synchronously inside the upload request handler** — this is a deliberate weakness, refactored on Day 1.

**v1 (after Day 1 refactor, 5 services):** add `redis` + `ingestion-worker` (ARQ). `POST /documents` returns 202 immediately; worker dequeues, runs `process_document()`, flips status to `ready`.

The synchronous code path lives in `api/app/services/ingestion.py`. `process_document()` is intentionally written to be **reused verbatim** by the worker — do not rewrite its chunk/embed logic when moving it. Only the call site in `api/app/routers/documents.py` changes (`ingest_document_sync(...)` → `await redis.enqueue_job("ingest_document", ...)`).

`api/app/core/metrics.py` already exposes Prometheus counters/gauges (incl. an `ingestion_queue_depth` placeholder) — Day 4 wires them into Grafana. `/metrics` is mounted in `app/main.py`.

## Day-by-day progression (track which day shapes your edits)

| Day | Touches | Notes |
|---|---|---|
| 1 | `ingestion-worker/`, `docker-compose.yml`, `api/app/services/ingestion.py`, `api/app/routers/documents.py` | Async refactor; **5** services |
| 2 | `.mcp.json` (copy from `.mcp.json.template`) | 4+ MCP servers, all pinned versions |
| 3 | `infra/` (Terraform), `.github/workflows/` | EKS + RDS pgvector + ElastiCache; OIDC, no long-lived keys |
| 4 | `observability/` | ServiceMonitor + Grafana dashboard + anomaly rules |
| 5 | `chatops-bot/` | Slack bot reusing Day 2 MCP backend |
| 6 | `security/` | Promptfoo red-team + cost dashboard |

Day N artifact builds on Day N-1 — don't skip.

## Conventions

- **Python:** `ruff format`, type hints required, `mypy --strict` target (Day 1 should-have).
- **Commits:** Conventional Commits (`feat:`, `fix:`, `refactor:`, `chore:`, `docs:`).
- **Branches:** `dayN-<topic>` (e.g. `day1-refactor`). **PR title:** `[Day N] <topic>`.
- **Secrets:** env vars only, never hardcoded; `.env` and `.mcp.json` are gitignored.
- **Forbidden patterns:**
  - Downgrading pgvector below 0.8.2 (CVE).
  - Changing `VECTOR(n)` without updating `EMBEDDING_DIM` (and vice versa).
  - Rewriting `process_document()` logic during Day 1 — move it, don't refactor it.
  - Using Celery instead of ARQ for the queue.
  - Modifying `web/` (frontend is provided complete).
  - Sanitizing `sample-docs/` (one file is an intentional injection payload for Day 6).

## Constraints (do not break)

- **`EMBEDDING_DIM` must equal the `VECTOR(n)` in `infra/db/init.sql`.** Default is 1024 (Gemini Matryoshka / Voyage). Switching to OpenAI `text-embedding-3-small` means `1536` **and** rebuilding the HNSW index. This is the single most common bug in the course.
- **pgvector ≥ 0.8.2 is mandatory** (CVE-2026-3172, CVSS 8.1 — parallel HNSW build buffer overflow). The compose image is pinned to `pgvector/pgvector:0.8.2-pg16`; don't downgrade.
- **`process_document()` must remain idempotent.** ARQ retries jobs — a partial run must not duplicate chunks or leave the document stuck in `pending`.
- **API contract is frozen.** Don't rename endpoints, change response shape, or alter the `documents.status` enum (`pending` / `ready` / `failed`) — verify scripts and the web client depend on them.
- **DB schema is frozen for Day 1.** Migrations come in Day 3 (the init-via-`docker-entrypoint-initdb.d` pattern won't survive RDS).
- **CLAUDE.md ≤ 200 lines.** `verify-day-1.sh` enforces this; beyond ~200 lines the agent silently drops middle context.

## LLM / Embedding provider matrix

Default provider is **Gemini** (free tier, `GEMINI_API_KEY` only). Anthropic, Ollama (on-prem profile), and a keyless `local` fallback (hash-based embeddings — pipeline runs but retrieval is poor) are also wired. See the `api` env block in `docker-compose.yml` for the full variable list; switch via `LLM_PROVIDER` + `EMBEDDING_PROVIDER` in `.env`.

Ollama runs only with `--profile ollama` and needs `docker compose exec ollama ollama pull deepseek-r1:14b` after first start (~9 GB, requires ≥ 16 GB RAM).

## Common commands

```bash
# Stack
docker compose up --build                       # v0 (3 services)
docker compose --profile ollama up --build      # v0 + local LLM
docker compose logs -f api                      # tail API logs
docker compose logs -f ingestion-worker         # (Day 1+)

# Verification (run BEFORE submitting each day; trainer runs the same script)
bash scripts/verify-setup.sh                    # pre-class env check
bash scripts/smoke-test.sh                      # v0 end-to-end
bash scripts/verify-day-1.sh                    # ... verify-day-7.sh

# API dev (inside api/)
uvicorn app.main:app --reload                   # http://localhost:8000/docs
pytest -xvs                                     # tests/ dir is created by the student

# Web dev (inside web/)
npm run dev                                     # http://localhost:3000
npm run build && npm run start                  # standalone production build
npm run lint
```

There is no test suite yet — Day 1 should add `api/tests/`. Style: `ruff format`, type hints, `mypy --strict` (Day 1 "should-have").

## Repo layout (only the non-obvious bits)

- `api/app/services/` — `ingestion.py` (the refactor target), `chunking.py`, `embeddings.py` (provider router), `llm.py`, `retrieval.py`.
- `api/app/core/` — `config.py` (pydantic-settings), `db.py` (psycopg3 pool), `metrics.py` (Prometheus, pre-wired for Day 4).
- `ingestion-worker/` — only a README at v0; Day 1 fills it with `worker/tasks.py` + `worker/settings.py` (ARQ `WorkerSettings`) + `Dockerfile` + `requirements.txt`.
- `web/` — Next.js 15 App Router, standalone output. Treat as black box; students do not modify the frontend.
- `infra/db/init.sql` — schema bootstrap (HNSW `m=16, ef_construction=64`). Loaded by Postgres init hook at v0; replaced by a migration tool in Day 3.
- `sample-docs/` — RAG test corpus. **One file contains a deliberate prompt-injection payload** for Day 6 red-teaming; don't sanitize it.
- `scripts/verify-day-N.sh` — authoritative pass/fail per day.
- `.mcp.json.template` → copy to `.mcp.json` on Day 2 (gitignored — contains paths/tokens).
- `docs/reference-solutions/` — trainer-only. **Do not read** while attempting a day; it spoils the exercise.

## Refactor guardrails (Day 1 specifics)

- Use **ARQ**, not Celery — chosen for native async + lighter footprint. `arq==0.26.3` is already in `api/requirements.txt`.
- API and worker must share the **same `REDIS_URL`** env var.
- Don't call `process_document()` (sync) from inside an async handler without `run_in_executor` — it blocks the loop ("event loop already running" is the symptom).
- Worker `Dockerfile` should share the api base image (same deps) and only differ in `CMD` (`arq worker.settings.WorkerSettings`).
- Add `arq`, `psycopg[binary]`, `pgvector`, and the chosen embedding SDK to `ingestion-worker/requirements.txt` — `Module not found: arq` at build time means this step was skipped.

## Domain

- **RAG pipeline:** upload → `extract_text` (pypdf / txt / md) → `chunk_text` → `embed` (batched) → store in `chunks` (pgvector) → on query: embed question → HNSW cosine retrieve top-k → LLM generates answer grounded in retrieved chunks.
- **Vector similarity:** cosine (`vector_cosine_ops`), HNSW index `m=16, ef_construction=64` (good for 768–1536 dim embeddings, lab-tuned in `infra/db/init.sql`).
- **Document status FSM:** `pending` → `ready` | `failed`. No other transitions. Failed docs stay failed; client retries by re-uploading.
- **Embedding dim 1024** is what fits: Voyage-3.5 native, Gemini via Matryoshka `output_dimensionality=1024`, Ollama truncated to 1024 in code. OpenAI = 1536 (would require schema change).
- **Input type matters:** `embed(..., input_type="document")` for ingestion, `input_type="query"` for retrieval — some providers (Voyage) tune embeddings differently per type.

## References

- Spec đầy đủ 7 ngày: `Running-Project-Specification-Student.md`
- Onboarding học viên: `GETTING_STARTED.md`
- Daily workflow + submission: `docs/DAILY-WORKFLOW.md`
- Lab guide Day N: `docs/lab-guides/DayN-*.md`
- Pre-reading Day N: `docs/pre-reading/DayN-*.md`
- Troubleshooting: `docs/STUDENT-FAQ.md`
- pgvector: https://github.com/pgvector/pgvector
- ARQ (async Redis queue): https://arq-docs.helpmanual.io/
- FastAPI: https://fastapi.tiangolo.com/
- MCP spec: https://modelcontextprotocol.io/

## Active TODOs (running checklist across days)

- [ ] Day 1: split `ingestion-worker`, add Redis, async upload
- [ ] Day 2: configure `.mcp.json` (4+ servers, pinned versions)
- [ ] Day 3: Terraform module + GitHub Actions OIDC, deploy to EKS
- [ ] Day 4: ServiceMonitor + Grafana + anomaly rules + AI RCA
- [ ] Day 5: Slack ChatOps bot reusing MCP backend
- [ ] Day 6: Promptfoo red-team, threat model, cost dashboard
- [ ] Day 7: final showcase
