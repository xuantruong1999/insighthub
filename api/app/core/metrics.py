"""
InsightHub API — Prometheus metrics
Day 4 (AIOps) sẽ scrape /metrics. Các metric chọn lọc để dạy anomaly detection:
- latency LLM call (dễ inject spike)
- ingestion queue depth (dễ inject backlog sau khi tách worker)
- error counter
"""
from prometheus_client import Counter, Gauge, Histogram

# Request-level
http_requests_total = Counter(
    "insighthub_http_requests_total",
    "Tổng số HTTP request",
    ["method", "endpoint", "status"],
)

# RAG pipeline
rag_query_latency = Histogram(
    "insighthub_rag_query_latency_seconds",
    "Latency của 1 truy vấn RAG end-to-end",
    buckets=(0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0),
)

llm_call_latency = Histogram(
    "insighthub_llm_call_latency_seconds",
    "Latency của riêng LLM generation call",
    buckets=(0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 20.0, 60.0),
)

llm_tokens_total = Counter(
    "insighthub_llm_tokens_total",
    "Tổng token LLM theo loại — phục vụ FinOps Day 6",
    ["direction"],  # input | output
)

embedding_tokens_total = Counter(
    "insighthub_embedding_tokens_total",
    "Tổng token embedding — phục vụ FinOps Day 6",
)

# Ingestion
documents_total = Gauge(
    "insighthub_documents_total",
    "Số tài liệu theo trạng thái",
    ["status"],  # pending | ready | failed
)

ingestion_errors_total = Counter(
    "insighthub_ingestion_errors_total",
    "Số lần ingestion thất bại",
)

ingestion_queue_depth = Gauge(
    "insighthub_ingestion_queue_depth",
    "Số job ingestion đang chờ trong ARQ queue",
)
