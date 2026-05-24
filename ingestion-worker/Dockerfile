# InsightHub — ingestion worker
# Build context phải là project root (xem docker-compose.yml)
#   build:
#     context: .
#     dockerfile: ingestion-worker/Dockerfile
FROM python:3.11-slim

WORKDIR /app

# Tái sử dụng code api (process_document, db, config, services...)
COPY api/app /app/app
COPY ingestion-worker/worker /app/worker
COPY ingestion-worker/requirements.txt /app/requirements.txt

RUN pip install --no-cache-dir -r requirements.txt

ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1

CMD ["arq", "worker.settings.WorkerSettings"]
