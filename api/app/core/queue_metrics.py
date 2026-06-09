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
