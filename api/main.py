import os
import time
import logging

import asyncpg
from fastapi import FastAPI, Request, Response
from fastapi.responses import RedirectResponse
from dotenv import load_dotenv
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST,
)
from routers.journal_router import router as journal_router

load_dotenv()

# Configure basic console logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)

REQUESTS = Counter(
    "http_requests_total", "HTTP requests", ["method", "path", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency in seconds",
    ["method", "path"],
)
DB_UP = Gauge("db_up", "1 if the database is reachable, else 0")

app = FastAPI(title="LearningSteps API", description="A simple learning journal API for tracking daily work, struggles, and intentions")
app.include_router(journal_router)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    if request.url.path == "/metrics":
        return await call_next(request)
    start = time.perf_counter()
    status = "500"
    try:
        response = await call_next(request)
        status = str(response.status_code)
        return response
    finally:
        route = request.scope.get("route")
        path = route.path if route else "unmatched"
        LATENCY.labels(request.method, path).observe(time.perf_counter() - start)
        REQUESTS.labels(request.method, path, status).inc()


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse(url="/docs")

@app.get("/version", tags=["meta"])
def version():
    return {"app": "LearningSteps API", "version": "1.1-cicd-proof"}

@app.get("/metrics", include_in_schema=False)
async def metrics():
    try:
        conn = await asyncpg.connect(os.getenv("DATABASE_URL"), timeout=2)
        try:
            await conn.fetchval("SELECT 1")
        finally:
            await conn.close()
        DB_UP.set(1)
    except Exception:
        DB_UP.set(0)
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# Log when the app starts
logger.info("LearningSteps API started successfully")