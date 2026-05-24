"""ARQ WorkerSettings — chạy bằng: arq worker.settings.WorkerSettings"""
import os

from arq.connections import RedisSettings

from worker.tasks import ingest_document


class WorkerSettings:
    functions = [ingest_document]
    redis_settings = RedisSettings.from_dsn(
        os.getenv("REDIS_URL", "redis://redis:6379")
    )
    max_tries = 3            # retry 3 lần với exponential backoff
    job_timeout = 300        # 5 phút mỗi job
    keep_result = 3600       # giữ kết quả 1h để debug
    max_jobs = 4             # concurrency
