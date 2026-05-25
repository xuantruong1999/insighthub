"""
InsightHub API — Application entrypoint
RAG Notebook API gateway. Chạy: uvicorn app.main:app
"""
import logging
from contextlib import asynccontextmanager

from arq import create_pool
from arq.connections import RedisSettings
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app.core.config import get_settings
from app.core.db import close_pool, get_pool
from app.core.metrics import http_requests_total
from app.routers import chat, documents, health

settings = get_settings()
logging.basicConfig(level=settings.log_level)
logger = logging.getLogger("insighthub.main")


@asynccontextmanager
async def lifespan(app: FastAPI):
    get_pool()  # mở DB connection pool khi khởi động
    app.state.arq_pool = await create_pool(
        RedisSettings.from_dsn(settings.redis_url)
    )
    logger.info("InsightHub API started — env=%s", settings.environment)
    yield
    await app.state.arq_pool.close()
    close_pool()
    logger.info("InsightHub API stopped")


app = FastAPI(title=settings.app_name, version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # ⚠️ Day 6: siết lại cho production
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    response = await call_next(request)
    http_requests_total.labels(
        method=request.method,
        endpoint=request.url.path,
        status=response.status_code,
    ).inc()
    return response


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


app.include_router(health.router)
app.include_router(documents.router)
app.include_router(chat.router)


@app.get("/")
async def root():
    return {"service": "InsightHub API", "version": "0.1.0", "docs": "/docs"}
