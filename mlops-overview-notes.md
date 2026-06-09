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
