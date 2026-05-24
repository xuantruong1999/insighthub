"""
InsightHub API — Ingestion service

⚠️  CHÚ Ý DÀNH CHO TRAINING (Day 1):
Ở v0, hàm ingest_document() chạy ĐỒNG BỘ ngay trong request handler của API.
Đây là điểm yếu kiến trúc CỐ Ý:
  - Upload file lớn → request bị block, có thể timeout
  - Không scale worker độc lập được
  - Không retry / không theo dõi trạng thái job
  - Không có queue depth metric để observe (Day 4)

Bài tập Day 1: dùng Claude Code refactor — tách logic này thành
service 'ingestion-worker' riêng, đẩy job qua Redis queue (ARQ).
API chỉ nhận file, lưu metadata, enqueue job, trả về ngay.

Hàm process_document() bên dưới được viết sao cho có thể TÁI SỬ DỤNG
nguyên vẹn trong worker — chỉ cần đổi cách gọi (sync → enqueue).
"""
import logging

from app.core.db import get_conn
from app.services.chunking import chunk_text
from app.services.embeddings import embed

logger = logging.getLogger("insighthub.ingestion")


def extract_text(filename: str, content: bytes) -> str:
    """Trích text từ file. Hỗ trợ .txt, .md, .pdf."""
    lower = filename.lower()
    if lower.endswith((".txt", ".md")):
        return content.decode("utf-8", errors="ignore")
    if lower.endswith(".pdf"):
        import io

        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(content))
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    raise ValueError(f"Định dạng không hỗ trợ: {filename}")


def process_document(document_id: int, filename: str, content: bytes) -> int:
    """
    Pipeline xử lý 1 tài liệu: extract → chunk → embed → lưu pgvector.
    TÁI SỬ DỤNG ĐƯỢC: gọi trực tiếp (v0) hoặc trong ARQ worker (sau refactor).
    Trả về số chunk đã tạo.
    """
    text = extract_text(filename, content)
    chunks = chunk_text(text)
    if not chunks:
        logger.warning("Document %s không có nội dung", document_id)
        _update_status(document_id, "ready", chunk_count=0)
        return 0

    # Embed theo batch — embedding API là bottleneck chính
    vectors = embed(chunks, input_type="document")

    with get_conn() as conn:
        with conn.transaction():
            # Idempotent: ARQ có thể retry — xóa chunks cũ trước khi insert.
            conn.execute("DELETE FROM chunks WHERE document_id = %s", (document_id,))
            for chunk, vector in zip(chunks, vectors):
                conn.execute(
                    """
                    INSERT INTO chunks (document_id, chunk_text, embedding)
                    VALUES (%s, %s, %s::vector)
                    """,
                    (document_id, chunk, vector),
                )
            conn.execute(
                "UPDATE documents SET status = 'ready', chunk_count = %s WHERE id = %s",
                (len(chunks), document_id),
            )
    logger.info("Document %s: %d chunks ingested", document_id, len(chunks))
    return len(chunks)


def _update_status(document_id: int, status: str, chunk_count: int = 0):
    with get_conn() as conn:
        conn.execute(
            "UPDATE documents SET status = %s, chunk_count = %s WHERE id = %s",
            (status, chunk_count, document_id),
        )


def ingest_document_sync(document_id: int, filename: str, content: bytes) -> int:
    """
    v0: gọi đồng bộ trong API request handler.
    SAU REFACTOR Day 1: API thay bằng redis.enqueue_job(...) và hàm này
    được di chuyển sang ingestion-worker.
    """
    try:
        return process_document(document_id, filename, content)
    except Exception as exc:  # noqa: BLE001
        logger.error("Ingestion thất bại cho document %s: %s", document_id, exc)
        _update_status(document_id, "failed")
        raise
