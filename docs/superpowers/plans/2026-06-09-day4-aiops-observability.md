# Day 4 — AIOps Observability & Anomaly Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Instrument InsightHub trên minikube với Prometheus + Grafana, thêm PromQL anomaly detection, inject 3 incident và viết AI RCA — pass `scripts/verify-day-4.sh`.

**Architecture:** Vá metric `ingestion_queue_depth` còn thiếu (background poll trong API process đọc `ZCARD arq:queue`). Deploy stack + kube-prometheus-stack lên minikube. ServiceMonitor → Prometheus scrape `/metrics`. Grafana dashboard JSON (RED, ≥9 panel). Recording/alerting rules sinh adaptive anomaly band. Loadgen sinh baseline. Inject 3 incident, query Prometheus (MCP, fallback HTTP) → RCA JSON.

**Tech Stack:** FastAPI, ARQ/Redis, prometheus_client, kube-prometheus-stack (Prometheus Operator), Grafana, PromQL, promtool, Helm, minikube, jq.

**Reference spec:** `docs/superpowers/specs/2026-06-09-day4-aiops-observability-design.md`

---

## File Structure

| File | Trách nhiệm | Tác vụ |
|---|---|---|
| `api/app/core/metrics.py` | Thêm Gauge `ingestion_queue_depth` | Task 1 |
| `api/app/core/queue_metrics.py` | Hàm poll queue depth (testable) | Task 1 |
| `api/app/main.py` | Spawn background poll task trong lifespan | Task 2 |
| `api/tests/test_queue_metrics.py` | Unit test poll logic | Task 1 |
| `observability/servicemonitor.yaml` | ServiceMonitor cho Prometheus Operator | Task 5 |
| `observability/anomaly-rules.yaml` | Recording + alerting rules (adaptive band) | Task 7 |
| `observability/grafana-dashboards/insighthub.json` | Dashboard RED ≥9 panel | Task 6 |
| `scripts/loadgen-day4.sh` | Sinh tải baseline | Task 8 |
| `rca-reports/incident-1..3-*.json` | RCA report mỗi incident | Task 9-11 |
| `mlops-overview-notes.md` | MLOps concept notes | Task 12 |

**Thứ tự phụ thuộc:** 1→2 (code) → 3 (deploy) → 4 (kps) → 5 (servicemonitor, verify UP) → 8 (loadgen nền) → 6,7 (dashboard+rules) → 9,10,11 (incident+RCA) → 12 (notes) → 13 (verify).

---

## Task 1: Vá metric queue depth + poll logic (TDD)

**Files:**
- Modify: `api/app/core/metrics.py` (cuối file)
- Create: `api/app/core/queue_metrics.py`
- Test: `api/tests/test_queue_metrics.py`

- [ ] **Step 1: Thêm Gauge vào metrics.py**

Thêm vào cuối `api/app/core/metrics.py`:

```python
ingestion_queue_depth = Gauge(
    "insighthub_ingestion_queue_depth",
    "Số job ingestion đang chờ trong ARQ queue",
)
```

- [ ] **Step 2: Viết failing test**

Tạo `api/tests/test_queue_metrics.py`:

```python
import pytest

from app.core.metrics import ingestion_queue_depth
from app.core.queue_metrics import refresh_queue_depth


class FakeRedis:
    def __init__(self, n):
        self._n = n

    async def zcard(self, key):
        assert key == "arq:queue"
        return self._n


@pytest.mark.asyncio
async def test_refresh_sets_gauge_from_zcard():
    await refresh_queue_depth(FakeRedis(7))
    assert ingestion_queue_depth._value.get() == 7


@pytest.mark.asyncio
async def test_refresh_on_error_sets_zero():
    class Broken:
        async def zcard(self, key):
            raise RuntimeError("redis down")

    await refresh_queue_depth(Broken())
    assert ingestion_queue_depth._value.get() == 0
```

- [ ] **Step 3: Run test, verify FAIL**

Run: `cd api && python -m pytest tests/test_queue_metrics.py -v`
Expected: FAIL — `ModuleNotFoundError: app.core.queue_metrics`

- [ ] **Step 4: Implement queue_metrics.py**

Tạo `api/app/core/queue_metrics.py`:

```python
"""Poll độ sâu ARQ queue và cập nhật Gauge Prometheus.

ARQ mặc định lưu job chờ trong sorted set key "arq:queue".
"""
import asyncio
import logging

from app.core.metrics import ingestion_queue_depth

logger = logging.getLogger("insighthub.queue_metrics")

ARQ_QUEUE_KEY = "arq:queue"


async def refresh_queue_depth(redis) -> None:
    """Đọc ZCARD arq:queue, set gauge. Lỗi → set 0, không raise."""
    try:
        depth = await redis.zcard(ARQ_QUEUE_KEY)
        ingestion_queue_depth.set(depth)
    except Exception as exc:  # noqa: BLE001
        logger.warning("Không đọc được queue depth: %s", exc)
        ingestion_queue_depth.set(0)


async def queue_depth_loop(redis, interval: float = 5.0) -> None:
    """Vòng lặp nền cập nhật gauge mỗi `interval` giây."""
    while True:
        await refresh_queue_depth(redis)
        await asyncio.sleep(interval)
```

- [ ] **Step 5: Run test, verify PASS**

Run: `cd api && python -m pytest tests/test_queue_metrics.py -v`
Expected: PASS (2 passed)

> Nếu thiếu `pytest-asyncio`: `pip install pytest-asyncio` và thêm `asyncio_mode = auto` vào `api/pytest.ini` (hoặc `[tool.pytest.ini_options]`). Nếu file pytest config chưa có, tạo `api/pytest.ini`:
> ```ini
> [pytest]
> asyncio_mode = auto
> ```

- [ ] **Step 6: Commit**

```bash
git add api/app/core/metrics.py api/app/core/queue_metrics.py api/tests/test_queue_metrics.py api/pytest.ini
git commit -m "feat(day-4): add ingestion_queue_depth gauge + ARQ queue poll"
```

---

## Task 2: Wire poll task vào lifespan

**Files:**
- Modify: `api/app/main.py:25-35` (lifespan)

- [ ] **Step 1: Thêm import**

Trong `api/app/main.py`, thêm cạnh các import hiện có:

```python
import asyncio
from app.core.queue_metrics import queue_depth_loop
```

- [ ] **Step 2: Spawn task trong lifespan**

Sửa hàm `lifespan` (sau khi tạo `app.state.arq_pool`):

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    get_pool()
    app.state.arq_pool = await create_pool(
        RedisSettings.from_dsn(settings.redis_url)
    )
    app.state.queue_task = asyncio.create_task(
        queue_depth_loop(app.state.arq_pool)
    )
    logger.info("InsightHub API started — env=%s", settings.environment)
    yield
    app.state.queue_task.cancel()
    await app.state.arq_pool.close()
    close_pool()
    logger.info("InsightHub API stopped")
```

- [ ] **Step 3: Smoke check import**

Run: `cd api && python -c "import app.main"`
Expected: không lỗi import.

- [ ] **Step 4: Commit**

```bash
git add api/app/main.py
git commit -m "feat(day-4): start queue-depth poll loop in API lifespan"
```

---

## Task 3: Deploy stack lên minikube

**Files:** none (ops). Cần `GEMINI_API_KEY` trong `.env`.

- [ ] **Step 1: Start Docker Desktop + minikube**

```bash
minikube start --memory=8192 --cpus=4
kubectl config current-context   # phải = minikube
```
Expected: context `minikube`.

- [ ] **Step 2: Build image vào daemon minikube**

```bash
eval "$(minikube -p minikube docker-env)"   # Windows PowerShell: & minikube -p minikube docker-env --shell powershell | Invoke-Expression
docker build -t insighthub-api:latest ./api
docker build -t insighthub-worker:latest -f ingestion-worker/Dockerfile .
docker build -t insighthub-web:latest ./web
```

- [ ] **Step 3: Helm deploy**

```bash
GEMINI_KEY=$(grep '^GEMINI_API_KEY=' .env | cut -d= -f2-)
helm upgrade --install insighthub ./infra/helm/insighthub \
  -f infra/helm/values-dev.yaml -n insighthub --create-namespace \
  --set api.apiKeys.geminiApiKey="$GEMINI_KEY"
```

- [ ] **Step 4: Verify pods Ready**

Run: `kubectl get pods -n insighthub`
Expected: api, ingestion-worker, postgres, redis, web đều `Running`/`Ready`.

- [ ] **Step 5: Verify /metrics có queue depth**

```bash
kubectl port-forward -n insighthub svc/api 8000:8000 &
curl -s localhost:8000/metrics | grep insighthub_ingestion_queue_depth
```
Expected: thấy dòng `insighthub_ingestion_queue_depth 0.0`.

---

## Task 4: Cài kube-prometheus-stack

**Files:** none (ops).

- [ ] **Step 1: Add repo + install**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

- [ ] **Step 2: Verify operator + Prometheus Ready**

Run: `kubectl get pods -n monitoring`
Expected: `kps-kube-prometheus-stack-operator`, `prometheus-kps-...`, `kps-grafana-...` đều Running.

- [ ] **Step 3: Ghi nhớ release label**

Run: `kubectl get prometheus -n monitoring -o jsonpath='{.items[0].spec.serviceMonitorSelector}'`
Expected: thấy `matchLabels` với `release: kps` (dùng cho Task 5).

---

## Task 5: ServiceMonitor

**Files:**
- Create: `observability/servicemonitor.yaml`

- [ ] **Step 1: Viết manifest**

Tạo `observability/servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: insighthub-api
  namespace: insighthub
  labels:
    release: kps
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  namespaceSelector:
    matchNames:
      - insighthub
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

- [ ] **Step 2: Apply**

Run: `kubectl apply -f observability/servicemonitor.yaml`
Expected: `servicemonitor.monitoring.coreos.com/insighthub-api created`.

- [ ] **Step 3: Verify target UP**

```bash
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
curl -s 'localhost:9090/api/v1/targets' | jq -r '.data.activeTargets[] | select(.labels.job=="api") | .health'
```
Expected: `up`.
> Nếu DOWN: kiểm tra label service (`app.kubernetes.io/name: api`) và port name `http` khớp.

- [ ] **Step 4: Commit**

```bash
git add observability/servicemonitor.yaml
git commit -m "feat(day-4): ServiceMonitor for InsightHub api /metrics"
```

---

## Task 6: Grafana dashboard JSON (≥9 panel)

**Files:**
- Create: `observability/grafana-dashboards/insighthub.json`

- [ ] **Step 1: Viết dashboard JSON**

Tạo `observability/grafana-dashboards/insighthub.json`. 10 panel (RED). Mỗi panel có `datasource: "${DS_PROMETHEUS}"`, `gridPos`, `id`, `title`, `targets[].expr`. PromQL từng panel:

1. `sum(rate(insighthub_rag_query_latency_seconds_count[5m]))` — RAG query rate
2. `sum(rate(insighthub_http_requests_total{status=~"5.."}[5m])) / sum(rate(insighthub_http_requests_total[5m]))` — error rate
3. `histogram_quantile(0.50, sum by (le) (rate(insighthub_rag_query_latency_seconds_bucket[5m])))` — RAG p50
4. `histogram_quantile(0.95, sum by (le) (rate(insighthub_rag_query_latency_seconds_bucket[5m])))` — RAG p95
5. `histogram_quantile(0.99, sum by (le) (rate(insighthub_rag_query_latency_seconds_bucket[5m])))` — RAG p99
6. `histogram_quantile(0.95, sum by (le) (rate(insighthub_llm_call_latency_seconds_bucket[5m])))` — LLM p95
7. `insighthub_ingestion_queue_depth` — queue depth
8. `insighthub_documents_total` (legend `{{status}}`) — docs theo status
9. `sum(rate(insighthub_ingestion_errors_total[5m]))` — ingestion errors
10. `sum(rate(insighthub_llm_tokens_total[5m])) by (direction)` — LLM tokens (Day 6 bonus)

Khung tối thiểu (điền đủ 10 panel theo mẫu panel 1):

```json
{
  "__inputs": [
    {"name": "DS_PROMETHEUS", "label": "Prometheus", "type": "datasource", "pluginId": "prometheus"}
  ],
  "title": "InsightHub — RED + AIOps",
  "uid": "insighthub-red",
  "schemaVersion": 39,
  "version": 1,
  "time": {"from": "now-1h", "to": "now"},
  "panels": [
    {
      "id": 1,
      "title": "RAG query rate (req/s)",
      "type": "timeseries",
      "datasource": "${DS_PROMETHEUS}",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
      "targets": [
        {"expr": "sum(rate(insighthub_rag_query_latency_seconds_count[5m]))", "refId": "A"}
      ]
    }
  ]
}
```
> Lặp lại block panel cho id 2–10, tăng `gridPos.x/y` (mỗi panel w=12; x luân phiên 0/12, y += 8 mỗi hàng). Panel 2 dùng `"unit": "percentunit"`.

- [ ] **Step 2: Validate JSON + đếm panel**

Run: `jq '.panels | length' observability/grafana-dashboards/insighthub.json`
Expected: `10` (≥9).

- [ ] **Step 3: Import vào Grafana, verify có data**

```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80 &
# Grafana UI localhost:3000 (user admin; pass: kubectl get secret kps-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)
# Dashboards → Import → upload JSON → chọn datasource Prometheus
```
Expected: panel có dữ liệu (sau khi loadgen Task 8 chạy).

- [ ] **Step 4: Commit**

```bash
git add observability/grafana-dashboards/insighthub.json
git commit -m "feat(day-4): Grafana RED dashboard (10 panels)"
```

---

## Task 7: Anomaly rules (adaptive band)

**Files:**
- Create: `observability/anomaly-rules.yaml`

- [ ] **Step 1: Viết recording + alerting rules**

Tạo `observability/anomaly-rules.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: insighthub-anomaly
  namespace: insighthub
  labels:
    release: kps
spec:
  groups:
    - name: insighthub-anomaly-recording
      interval: 30s
      rules:
        # p95 LLM latency hiện tại
        - record: insighthub:llm_latency:p95
          expr: histogram_quantile(0.95, sum by (le) (rate(insighthub_llm_call_latency_seconds_bucket[5m])))
        # baseline = trung bình p95 trên window dài (lab: 1h thay vì 7d — trade-off)
        - record: insighthub:llm_latency:p95_baseline
          expr: avg_over_time(insighthub:llm_latency:p95[1h])
        - record: insighthub:llm_latency:p95_stddev
          expr: stddev_over_time(insighthub:llm_latency:p95[1h])
        # adaptive upper band = baseline + 3*stddev
        - record: insighthub:llm_latency:p95_upper_band
          expr: insighthub:llm_latency:p95_baseline + 3 * insighthub:llm_latency:p95_stddev
        # queue depth band
        - record: insighthub:queue_depth:baseline
          expr: avg_over_time(insighthub_ingestion_queue_depth[1h])
        - record: insighthub:queue_depth:upper_band
          expr: insighthub:queue_depth:baseline + 3 * stddev_over_time(insighthub_ingestion_queue_depth[1h])
    - name: insighthub-anomaly-alerting
      rules:
        - alert: LLMLatencyAnomaly
          expr: insighthub:llm_latency:p95 > insighthub:llm_latency:p95_upper_band
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "LLM latency p95 vượt anomaly band"
            description: "p95={{ $value }}s vượt upper band (baseline+3σ)."
        - alert: IngestionQueueAnomaly
          expr: insighthub_ingestion_queue_depth > insighthub:queue_depth:upper_band
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Ingestion queue depth bất thường"
```

- [ ] **Step 2: promtool check (chỉ phần rules)**

`PrometheusRule` là CRD; promtool cần file rule thuần. Tạo tạm và check:

```bash
yq '.spec.groups | {"groups": .}' observability/anomaly-rules.yaml > /tmp/rules.yaml 2>/dev/null \
  || python -c "import yaml,sys,json; d=yaml.safe_load(open('observability/anomaly-rules.yaml')); print(yaml.safe_dump({'groups': d['spec']['groups']}))" > /tmp/rules.yaml
promtool check rules /tmp/rules.yaml
```
Expected: `SUCCESS: ... rules found`.
> verify-day-4.sh chạy `promtool check rules` trên `observability/*.yaml` gộp lại — vì file là CRD, promtool có thể warn. Đảm bảo cú pháp PromQL hợp lệ là mục tiêu chính; nếu verify strict, cân nhắc đặt thêm bản rule thuần. (Xem Step 3.)

- [ ] **Step 3: Apply lên cluster**

Run: `kubectl apply -f observability/anomaly-rules.yaml`
Expected: `prometheusrule.monitoring.coreos.com/insighthub-anomaly created`.
Verify Prometheus nạp rule: `curl -s localhost:9090/api/v1/rules | jq '.data.groups[].name'` → thấy `insighthub-anomaly-recording`.

- [ ] **Step 4: Commit**

```bash
git add observability/anomaly-rules.yaml
git commit -m "feat(day-4): PromQL adaptive anomaly band rules (LLM latency + queue)"
```

---

## Task 8: Loadgen baseline

**Files:**
- Create: `scripts/loadgen-day4.sh`

- [ ] **Step 1: Viết script**

Tạo `scripts/loadgen-day4.sh`:

```bash
#!/usr/bin/env bash
# Sinh tải baseline cho anomaly detection. Cần port-forward svc/api 8000.
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
```
> Đối chiếu endpoint thật trong `api/app/routers/` nếu `/documents`/`/chat` khác. Chọn 1 file thật trong `sample-docs/` (không phải file payload injection).

- [ ] **Step 2: Chạy nền ≥1h**

```bash
chmod +x scripts/loadgen-day4.sh
API=http://localhost:8000 bash scripts/loadgen-day4.sh &
```
Expected: metric history tích lũy; sau ~1h baseline rule có giá trị khác 0.

- [ ] **Step 3: Verify baseline có data**

Run: `curl -s 'localhost:9090/api/v1/query?query=insighthub:llm_latency:p95_baseline' | jq '.data.result'`
Expected: result không rỗng.

- [ ] **Step 4: Commit**

```bash
git add scripts/loadgen-day4.sh
git commit -m "chore(day-4): baseline load generator for anomaly detection"
```

---

## Task 9: Incident #1 — LLM latency spike + RCA

**Files:**
- Create: `rca-reports/incident-1-llm-latency-spike.json`

- [ ] **Step 1: Inject spike**

Cách đơn giản (không sửa code): chuyển provider sang một cấu hình chậm hoặc thêm sleep qua env. Nếu app có `LLM_PROVIDER=local` (hash) thì spike khó; thay vào đó dùng Gemini thật và bơm nhiều request đồng thời để latency p95 tăng:
```bash
for i in $(seq 1 20); do curl -s -X POST localhost:8000/chat -H 'Content-Type: application/json' -d '{"question":"Summarize everything in detail"}' & done; wait
```
> Mục tiêu: `insighthub:llm_latency:p95` vượt `insighthub:llm_latency:p95_upper_band`.

- [ ] **Step 2: Query evidence (MCP, fallback HTTP)**

Ưu tiên Prometheus MCP:
- `mcp__prometheus__prom_query` với `query=insighthub:llm_latency:p95`
- `mcp__prometheus__prom_query` với `query=insighthub:llm_latency:p95_upper_band`

Fallback HTTP:
```bash
curl -s 'localhost:9090/api/v1/query?query=insighthub:llm_latency:p95' | jq '.data.result[0].value'
```

- [ ] **Step 3: Viết RCA JSON**

Tạo `rca-reports/incident-1-llm-latency-spike.json` (điền giá trị thật quan sát được):

```json
{
  "incident_id": "incident-1-llm-latency-spike",
  "detected_at": "2026-06-09T00:00:00Z",
  "symptom": "RAG response chậm; LLM call latency p95 tăng đột biến vượt anomaly band.",
  "affected_service": "api",
  "metrics_observed": {
    "insighthub:llm_latency:p95": "<giá trị thật>s",
    "insighthub:llm_latency:p95_upper_band": "<giá trị thật>s"
  },
  "top_hypotheses": [
    {
      "hypothesis": "LLM provider trả chậm do nhiều request đồng thời / rate limit.",
      "confidence": 0.8,
      "evidence": [
        "insighthub:llm_latency:p95 = <x>s > upper_band = <y>s",
        "RAG query rate tăng cùng thời điểm (rate(...count[5m]))"
      ]
    }
  ],
  "recommended_fix": "Thêm concurrency limit / retry-backoff cho LLM call; cân nhắc cache hoặc provider nhanh hơn."
}
```

- [ ] **Step 4: Verify schema**

Run: `jq -e '.top_hypotheses[0].evidence' rca-reports/incident-1-llm-latency-spike.json`
Expected: in ra mảng evidence (exit 0).

- [ ] **Step 5: Revert + commit**

Dừng burst, đợi p95 về dưới band.
```bash
git add rca-reports/incident-1-llm-latency-spike.json
git commit -m "docs(day-4): RCA incident-1 LLM latency spike"
```

---

## Task 10: Incident #2 — Queue backlog + RCA

**Files:**
- Create: `rca-reports/incident-2-queue-backlog.json`

- [ ] **Step 1: Inject backlog (dừng worker)**

```bash
kubectl scale deployment ingestion-worker -n insighthub --replicas=0
for i in $(seq 1 10); do curl -s -F "file=@sample-docs/service-level-objectives.md" localhost:8000/documents >/dev/null; done
```
Expected: `insighthub_ingestion_queue_depth` tăng dần và không giảm; documents kẹt `pending`.

- [ ] **Step 2: Query evidence**

MCP `mcp__prometheus__prom_query` query=`insighthub_ingestion_queue_depth` (và `insighthub:queue_depth:upper_band`).
Fallback: `curl -s 'localhost:9090/api/v1/query?query=insighthub_ingestion_queue_depth' | jq '.data.result[0].value'`

- [ ] **Step 3: Viết RCA JSON**

Tạo `rca-reports/incident-2-queue-backlog.json`:

```json
{
  "incident_id": "incident-2-queue-backlog",
  "detected_at": "2026-06-09T00:00:00Z",
  "symptom": "Documents kẹt trạng thái pending; queue depth tăng đơn điệu.",
  "affected_service": "ingestion-worker",
  "metrics_observed": {
    "insighthub_ingestion_queue_depth": "<giá trị thật>",
    "insighthub_documents_total{status=\"pending\"}": "<giá trị thật>"
  },
  "top_hypotheses": [
    {
      "hypothesis": "Ingestion worker dừng/scale=0 nên không dequeue job.",
      "confidence": 0.95,
      "evidence": [
        "insighthub_ingestion_queue_depth tăng đơn điệu không giảm",
        "documents_total{status=pending} tăng, status=ready đứng yên",
        "kubectl: ingestion-worker replicas=0"
      ]
    }
  ],
  "recommended_fix": "Scale worker trở lại (>=1); thêm HPA theo queue depth; alert IngestionQueueAnomaly."
}
```

- [ ] **Step 4: Verify schema**

Run: `jq -e '.top_hypotheses[0].evidence' rca-reports/incident-2-queue-backlog.json`
Expected: exit 0.

- [ ] **Step 5: Revert + commit**

```bash
kubectl scale deployment ingestion-worker -n insighthub --replicas=1
git add rca-reports/incident-2-queue-backlog.json
git commit -m "docs(day-4): RCA incident-2 queue backlog"
```

---

## Task 11: Incident #3 — Error burst + RCA

**Files:**
- Create: `rca-reports/incident-3-error-burst.json`

- [ ] **Step 1: Inject error (DB sai)**

```bash
kubectl scale deployment postgres -n insighthub --replicas=0   # hoặc set DATABASE_URL sai rồi rollout
for i in $(seq 1 10); do curl -s -F "file=@sample-docs/service-level-objectives.md" localhost:8000/documents >/dev/null; done
```
Expected: `insighthub_ingestion_errors_total` tăng; HTTP 5xx tăng.

- [ ] **Step 2: Query evidence**

MCP query=`rate(insighthub_ingestion_errors_total[5m])` và `rate(insighthub_http_requests_total{status=~"5.."}[5m])`.
Fallback HTTP tương tự Task 9.

- [ ] **Step 3: Viết RCA JSON**

Tạo `rca-reports/incident-3-error-burst.json`:

```json
{
  "incident_id": "incident-3-error-burst",
  "detected_at": "2026-06-09T00:00:00Z",
  "symptom": "Ingestion thất bại hàng loạt; HTTP 5xx tăng đột biến.",
  "affected_service": "api / postgres",
  "metrics_observed": {
    "rate(insighthub_ingestion_errors_total[5m])": "<giá trị thật>",
    "rate(insighthub_http_requests_total{status=~\"5..\"}[5m])": "<giá trị thật>"
  },
  "top_hypotheses": [
    {
      "hypothesis": "Postgres không reachable (down/DATABASE_URL sai) nên ingestion lỗi.",
      "confidence": 0.9,
      "evidence": [
        "insighthub_ingestion_errors_total tăng đột biến",
        "http_requests_total{status=5xx} tăng cùng lúc",
        "postgres pod replicas=0 / connection refused trong log api"
      ]
    }
  ],
  "recommended_fix": "Khôi phục postgres; sửa DATABASE_URL; thêm readiness gate + circuit breaker cho DB."
}
```

- [ ] **Step 4: Verify schema**

Run: `jq -e '.top_hypotheses[0].evidence' rca-reports/incident-3-error-burst.json`
Expected: exit 0.

- [ ] **Step 5: Revert + commit**

```bash
kubectl scale deployment postgres -n insighthub --replicas=1
git add rca-reports/incident-3-error-burst.json
git commit -m "docs(day-4): RCA incident-3 error burst"
```

---

## Task 12: MLOps overview notes

**Files:**
- Create: `mlops-overview-notes.md` (root)

- [ ] **Step 1: Viết notes (≥4 block)**

Tạo `mlops-overview-notes.md`. Phải chứa ≥4 trong các heading: Mindset, Lifecycle, Registry, Approval, Drift, Rollback, Ownership (verify grep các từ này):

```markdown
# MLOps Overview — góc nhìn DevOps (Day 4)

> DevOps KHÔNG train model. Model là một service: có version, latency, cost, cần monitor & rollback.

## Mindset
Model-as-a-service: coi LLM/embedding provider như một dependency có SLA, version, và chi phí.

## Lifecycle
Data → train/tune (ML eng) → eval → package → deploy → monitor → retrain. DevOps sở hữu từ deploy về sau.

## Registry
Model version được pin (vd `gemini-*`, embedding dim 1024). Đổi version = đổi artifact, cần test lại retrieval.

## Approval
Promote model mới qua gate (eval pass, cost trong ngưỡng) trước khi lên prod — tương tự CI gate cho code.

## Drift
Embedding/LLM drift khi đổi provider hoặc data thay đổi → retrieval kém. Monitor qua chất lượng answer + latency.

## Rollback
Pin version cho phép rollback nhanh khi model mới hồi quy chất lượng/cost. Giữ artifact cũ sẵn sàng.

## Ownership
ML eng: model logic. DevOps: deploy, observability, cost, rollback, reliability.
```

- [ ] **Step 2: Verify block count**

Run: `grep -cE "Mindset|Lifecycle|Registry|Approval|Drift|Rollback|Ownership" mlops-overview-notes.md`
Expected: ≥ 4 (ở đây 7).

- [ ] **Step 3: Commit**

```bash
git add mlops-overview-notes.md
git commit -m "docs(day-4): MLOps overview notes (model-as-a-service)"
```

---

## Task 13: Verify Day 4

**Files:** none.

- [ ] **Step 1: Chạy verify script**

Run: `bash scripts/verify-day-4.sh`
Expected: tất cả `[PASS]`, dòng cuối `✅ Day 4 OK`, exit 0.

- [ ] **Step 2: Sửa FAIL nếu có**

Đối chiếu từng FAIL với task tương ứng:
- ServiceMonitor → Task 5
- Anomaly rules / promtool → Task 7
- Dashboard panels <9 → Task 6
- RCA <3 / thiếu evidence → Task 9-11
- mlops notes → Task 12

- [ ] **Step 3: Commit cuối (nếu có chỉnh)**

```bash
git add -A && git commit -m "chore(day-4): fixes to pass verify-day-4.sh"
```

---

## Self-Review notes

- **Spec coverage:** Khối A→Task 1-2; B→Task 3-4; C1→Task 5; C2→Task 6; C3→Task 7; D→Task 8; E→Task 9-11; F→Task 12; verify→Task 13. ✅ đủ.
- **Tên rule nhất quán:** `insighthub:llm_latency:p95_baseline` / `_upper_band`, `insighthub:queue_depth:baseline` / `_upper_band` dùng nhất quán giữa Task 7 và Task 9/10. Regex verify (`_baseline`/`_upper_band`) khớp.
- **Metric name nhất quán:** `insighthub_ingestion_queue_depth` (Task 1) = panel (Task 6) = rule (Task 7) = incident #2 (Task 10).
- **Cảnh báo promtool:** verify chạy promtool trên file CRD `PrometheusRule`; nếu strict-fail, có thể cần xuất thêm bản rule thuần — ghi rõ ở Task 7 Step 2.
- **Endpoint loadgen/incident** (`/documents`, `/chat`) cần đối chiếu router thật trước khi chạy (ghi chú ở Task 8/9).
