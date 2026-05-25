"""
InsightHub API — Documents router

Day 1 refactor: upload chỉ lưu metadata + enqueue ARQ job, trả 202 ngay.
Worker (ingestion-worker) sẽ xử lý chunk/embed/store bất đồng bộ.
"""
import logging

from fastapi import APIRouter, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse

from app.core.db import get_conn
from app.core.metrics import documents_total, ingestion_errors_total

logger = logging.getLogger("insighthub.routers.documents")
router = APIRouter(prefix="/documents", tags=["documents"])

ALLOWED_EXT = (".txt", ".md", ".pdf")
MAX_SIZE_MB = 10


@router.post("", status_code=202)
async def upload_document(file: UploadFile, request: Request):
    if not file.filename or not file.filename.lower().endswith(ALLOWED_EXT):
        raise HTTPException(400, f"Chỉ chấp nhận: {', '.join(ALLOWED_EXT)}")

    content = await file.read()
    if len(content) > MAX_SIZE_MB * 1024 * 1024:
        raise HTTPException(413, f"File vượt quá {MAX_SIZE_MB}MB")

    # Lưu metadata, trạng thái 'pending'
    with get_conn() as conn:
        row = conn.execute(
            "INSERT INTO documents (filename, status) VALUES (%s, 'pending') RETURNING id",
            (file.filename,),
        ).fetchone()
        document_id = row[0]

    # Enqueue ARQ job — worker sẽ dequeue và xử lý
    redis = request.app.state.arq_pool
    try:
        await redis.enqueue_job("ingest_document", document_id, file.filename, content)
    except Exception as exc:  # noqa: BLE001
        ingestion_errors_total.inc()
        logger.exception("Enqueue thất bại cho document %s", document_id)
        raise HTTPException(503, f"Queue không khả dụng: {exc}") from exc

    return JSONResponse(
        status_code=202,
        content={
            "id": document_id,
            "filename": file.filename,
            "status": "pending",
        },
    )


@router.get("/{document_id}/status")
async def get_document_status(document_id: int):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, filename, status, chunk_count FROM documents WHERE id = %s",
            (document_id,),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "Không tìm thấy tài liệu")
    return {
        "id": row[0],
        "filename": row[1],
        "status": row[2],
        "chunk_count": row[3],
    }


@router.get("")
async def list_documents():
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, filename, status, chunk_count, created_at "
            "FROM documents ORDER BY created_at DESC"
        ).fetchall()

    # Cập nhật gauge cho Prometheus
    counts: dict[str, int] = {}
    for r in rows:
        counts[r[2]] = counts.get(r[2], 0) + 1
    for status in ("pending", "ready", "failed"):
        documents_total.labels(status=status).set(counts.get(status, 0))

    return [
        {
            "id": r[0],
            "filename": r[1],
            "status": r[2],
            "chunk_count": r[3],
            "created_at": r[4].isoformat() if r[4] else None,
        }
        for r in rows
    ]


@router.delete("/{document_id}", status_code=204)
async def delete_document(document_id: int):
    with get_conn() as conn:
        result = conn.execute(
            "DELETE FROM documents WHERE id = %s RETURNING id", (document_id,)
        ).fetchone()
    if result is None:
        raise HTTPException(404, "Không tìm thấy tài liệu")
