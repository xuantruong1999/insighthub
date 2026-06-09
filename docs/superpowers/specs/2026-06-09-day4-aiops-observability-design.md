# Day 4 — AIOps Observability & Anomaly Detection (Design)

> Spec ngày: 2026-06-09 · Running project: InsightHub · Pillar B (Operate)
> Mode: **full live trên minikube** (deploy thật, scrape thật, inject incident thật, RCA từ số liệu thật).

## 1. Mục tiêu & tiêu chí pass

Bám `scripts/verify-day-4.sh` (spec chấm điểm chính thức). 5 nhóm artifact:

| # | File | Điều kiện pass |
|---|---|---|
| 1 | `observability/servicemonitor.yaml` | tồn tại; Prometheus target `insighthub api` = `UP` |
| 2 | `observability/anomaly-rules.yaml` | recording rules chứa `_baseline` + `_upper_band` (regex `_anomaly|_upper_band|_baseline`); `promtool check rules` SUCCESS |
| 3 | `observability/grafana-dashboards/insighthub.json` | `.panels \| length` **≥ 9**; panel có data khi import |
| 4 | `rca-reports/incident-*.json` | **≥ 3** file; mỗi file có `.top_hypotheses[0].evidence` |
| 5 | `mlops-overview-notes.md` (root) | ≥ 4 block trong {Mindset, Lifecycle, Registry, Approval, Drift, Rollback, Ownership} |

Lưu ý: verify ép **PromQL-based anomaly (Option A)** — Grafana Cloud ML không pass vì script grep tên rule.

## 2. Quyết định đã chốt

- **Vá metric `insighthub_ingestion_queue_depth`** (task tồn đọng Day 1) — để panel queue depth + anomaly + incident #2 có data thật.
- **RCA evidence**: ưu tiên Prometheus MCP (`mcp__prometheus__*`, đang có trong session); fallback query trực tiếp HTTP API / promtool nếu MCP không tới được Prometheus.
- **Anomaly**: PromQL adaptive band (mean ± k·stddev) qua recording rules.

## 3. Kiến trúc & luồng dữ liệu

```
InsightHub (/metrics, port http:8000)
        │  scrape (ServiceMonitor, 30s)
        ▼
kube-prometheus-stack (Prometheus + recording/alerting rules)
        │
        ├──► Grafana (dashboard RED, import JSON)
        └──► Prometheus MCP ──► Claude correlate ──► rca-reports/*.json
```

## 4. Các khối triển khai

### Khối A — Vá metric queue depth (tiền đề, đụng app code)

- **`api/app/core/metrics.py`**: thêm
  ```python
  ingestion_queue_depth = Gauge(
      "insighthub_ingestion_queue_depth",
      "Số job ingestion đang chờ trong ARQ queue",
  )
  ```
- **Cập nhật giá trị**: background asyncio task trong API process (vì `/metrics` nằm ở api), khởi động ở lifespan của `app/main.py`, mỗi ~5s đọc `ZCARD arq:queue` (ARQ default queue = sorted set `arq:queue`) qua redis client rồi `ingestion_queue_depth.set(n)`.
- **Ràng buộc**: không sửa logic `process_document()`; giữ idempotent; nếu redis lỗi → set 0 + log, không crash app.
- **Rủi ro/biên**: tên queue ARQ phải khớp (`arq:queue` mặc định; xác nhận trong settings). Nếu queue rỗng → 0 là đúng.

### Khối B — Hạ tầng quan sát (minikube)

1. Start Docker Desktop → `minikube start` (RAM ≥ 6–8GB cho stack + kps).
2. `eval $(minikube docker-env)` → build lại image api/worker/web (`pullPolicy: Never`).
3. `helm upgrade --install insighthub ./infra/helm/insighthub -f infra/helm/values-dev.yaml -n insighthub --create-namespace --set api.apiKeys.geminiApiKey=<key từ .env>`.
4. `helm repo add prometheus-community ...` → `helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace`.
5. `kubectl rollout restart deployment api ingestion-worker -n insighthub` sau khi đổi secret/rebuild (image `:latest` không tự reload).

### Khối C — Artifacts observability/

**C1. `servicemonitor.yaml`**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: insighthub-api
  namespace: insighthub
  labels:
    release: kps          # để serviceMonitorSelector của kps nhặt được
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  namespaceSelector:
    matchNames: [insighthub]
  endpoints:
    - port: http          # tên port của Service api
      path: /metrics
      interval: 30s
```

**C2. `grafana-dashboards/insighthub.json`** — ≥9 panel (RED method):
1. RAG query rate (req/s) — `rate(insighthub_rag_query_latency_seconds_count[5m])`
2. RAG error rate (%) — từ `insighthub_http_requests_total{status=~"5.."}`
3. RAG latency p50 — `histogram_quantile(0.5, ...)`
4. RAG latency p95
5. RAG latency p99
6. LLM call latency p95 — `insighthub_llm_call_latency_seconds_bucket`
7. Ingestion queue depth — `insighthub_ingestion_queue_depth`
8. Documents theo status — `insighthub_documents_total{status=...}`
9. Ingestion errors — `rate(insighthub_ingestion_errors_total[5m])`
10. (bonus) LLM tokens rate — phục vụ Day 6.

Datasource để `${DS_PROMETHEUS}` templated cho import.

**C3. `anomaly-rules.yaml`** — adaptive band cho `insighthub_llm_call_latency_seconds` (+ queue depth):
- recording: `..._baseline` = avg p95 trên window dài (vd `avg_over_time(...[1h])`); `..._stddev`; `..._upper_band` = baseline + 3·stddev.
- alerting: `LLMLatencyAnomaly` khi p95 hiện tại > `..._upper_band` trong N phút.
- `promtool check rules` phải SUCCESS.
- Trade-off baseline: lab không có 7 ngày → dùng window ngắn (1h) + chú thích rõ trong file.

### Khối D — Baseline data (load generation)

- `scripts/loadgen-day4.sh` (hoặc python): vòng lặp upload sample-doc + gọi query RAG đều đặn để sinh metric history.
- Chạy nền ≥ 1h trước khi bật/đánh giá anomaly (giảm window so với 7 ngày, ghi chú trade-off).

### Khối E — Inject 3 incident + AI RCA

Mỗi incident: inject → đợi metric phản ứng → query Prometheus (MCP, fallback HTTP) → Claude correlate RED → xuất `rca-reports/incident-<n>-<slug>.json`.

Schema mỗi file (tối thiểu để pass verify + có ý nghĩa):
```json
{
  "incident_id": "incident-1-llm-latency-spike",
  "detected_at": "<ts>",
  "symptom": "...",
  "affected_service": "api",
  "top_hypotheses": [
    {"hypothesis": "...", "confidence": 0.8, "evidence": ["PromQL + giá trị quan sát"]}
  ],
  "recommended_fix": "..."
}
```

3 kịch bản:
1. **LLM latency spike** — set env mock chậm / provider latency → `insighthub_llm_call_latency_seconds` p95 vượt band.
2. **Queue backlog** — `kubectl scale deploy ingestion-worker --replicas=0` → upload vài doc → `insighthub_ingestion_queue_depth` tăng không giảm, docs kẹt `pending`.
3. **Error burst** — đổi `DATABASE_URL` sai (hoặc tắt postgres) → `insighthub_ingestion_errors_total` + HTTP 5xx tăng.

Sau mỗi incident: revert về trạng thái healthy trước khi inject cái tiếp theo.

### Khối F — MLOps notes

`mlops-overview-notes.md` ở root, ≥4 block trong tập {Mindset, Lifecycle, Registry, Approval, Drift, Rollback, Ownership}. Góc nhìn "model as a service" cho DevOps (không train model).

## 5. Thứ tự thực hiện (phụ thuộc)

A (code metric) → B (deploy) → C1 (servicemonitor, verify UP) → D (loadgen, chạy nền) → C2/C3 (dashboard + rules trên metric đã có data) → E (inject + RCA) → F (notes) → chạy `verify-day-4.sh`.

## 6. Ngoài phạm vi (YAGNI)

- Không dùng Grafana Cloud ML / Pro.
- Không train/tune model thật (MLOps chỉ là notes khái niệm).
- Không deploy EKS thật (đó là Day 3; Day 4 dùng minikube).
- Không sửa `web/`, không đụng `sample-docs/` payload.

## 7. Rủi ro & giảm thiểu

| Rủi ro | Giảm thiểu |
|---|---|
| Minikube thiếu RAM khi thêm kps | Tăng RAM minikube; tắt component kps không cần (alertmanager nếu nặng) |
| ServiceMonitor không được nhặt | Thêm label `release: kps` khớp serviceMonitorSelector |
| Anomaly thiếu baseline | Loadgen + giảm window, ghi chú trade-off |
| ARQ queue key sai tên | Xác nhận `arq:queue`; test `ZCARD` thủ công |
| Prometheus MCP không tới Prometheus | Fallback HTTP API qua port-forward |
| Đổi secret không reload | `kubectl rollout restart` (đã ghi memory) |

## 8. Verify cuối

`bash scripts/verify-day-4.sh` → kỳ vọng tất cả PASS, 0 FAIL.
