"""
ARQ tasks — InsightHub ingestion worker.

Tái sử dụng process_document() từ api/app/services/ingestion.py.
process_document() là SYNC nên bọc run_in_executor để không block event loop.
"""
import asyncio
import logging

from app.services.ingestion import _update_status, process_document

logger = logging.getLogger("worker.tasks")


async def ingest_document(
    ctx: dict, document_id: int, filename: str, content: bytes
) -> int:
    logger.info("Worker picked up document %s (%s)", document_id, filename)
    try:
        loop = asyncio.get_event_loop()
        chunk_count = await loop.run_in_executor(
            None, process_document, document_id, filename, content
        )
        logger.info("Document %s ingested: %d chunks", document_id, chunk_count)
        return chunk_count
    except Exception as exc:
        logger.exception("Ingest failed for document %s: %s", document_id, exc)
        _update_status(document_id, "failed")
        raise
