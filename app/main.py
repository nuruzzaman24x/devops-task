"""
DevOps Task - Small web service
Reads all config from environment variables, emits structured JSON logs to stdout,
exposes Prometheus metrics, and shuts down gracefully on SIGTERM.
"""
import json
import logging
import os
import sys
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

OTEL_ENABLED = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") is not None

if OTEL_ENABLED:  # pragma: no cover - exercised only with a real OTLP collector
    _resource = Resource.create({"service.name": "devops-task"})
    _provider = TracerProvider(resource=_resource)
    _otel_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    _exporter = OTLPSpanExporter(endpoint=_otel_endpoint, insecure=True)
    _provider.add_span_processor(BatchSpanProcessor(_exporter))
    trace.set_tracer_provider(_provider)

# ---------------------------------------------------------------------------
# Configuration (all from environment variables)
# ---------------------------------------------------------------------------
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
APP_ENV = os.getenv("APP_ENV", "development")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
PORT = int(os.getenv("PORT", "8080"))

# ---------------------------------------------------------------------------
# Structured JSON logging to stdout
# ---------------------------------------------------------------------------
EXTRA_FIELDS = ("method", "path", "status", "duration_ms")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "env": APP_ENV,
        }
        # Request fields (passed via logger extra=...) become top-level JSON keys
        for key in EXTRA_FIELDS:
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def configure_logging() -> logging.Logger:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))
    return logging.getLogger("devops-task")


logger = configure_logging()

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total number of HTTP requests",
    ["method", "path", "status"],
)
ERROR_COUNT = Counter(
    "http_requests_errors_total",
    "Total number of HTTP requests that resulted in a 5xx error",
    ["method", "path"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "path"],
)

# ---------------------------------------------------------------------------
# Graceful shutdown handling
# ---------------------------------------------------------------------------
_shutting_down = False


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"Starting up (version={APP_VERSION}, env={APP_ENV}, port={PORT})")
    yield
    global _shutting_down
    _shutting_down = True
    logger.info("SIGTERM received, uvicorn shutdown complete")


app = FastAPI(title="DevOps Task Service", lifespan=lifespan)

if OTEL_ENABLED:  # pragma: no cover - exercised only with a real OTLP collector
    FastAPIInstrumentor().instrument_app(app)

QUIET_PATHS = {"/health", "/metrics"}  # probes/scrapes: log at DEBUG to avoid noise


def route_label(request: Request) -> str:
    """Use the matched route template for metric labels (low cardinality).
    Unknown paths (404, scanners) all collapse into one 'unmatched' label."""
    route = request.scope.get("route")
    return getattr(route, "path", "unmatched")


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    raw_path = request.url.path
    try:
        response = await call_next(request)
    except Exception:
        label = route_label(request)
        ERROR_COUNT.labels(method=request.method, path=label).inc()
        REQUEST_COUNT.labels(method=request.method, path=label, status="500").inc()
        logger.exception(
            "Unhandled exception while processing request",
            extra={"method": request.method, "path": raw_path, "status": 500},
        )
        raise
    duration = time.perf_counter() - start
    label = route_label(request)
    REQUEST_LATENCY.labels(method=request.method, path=label).observe(duration)
    REQUEST_COUNT.labels(
        method=request.method, path=label, status=str(response.status_code)
    ).inc()
    if response.status_code >= 500:
        ERROR_COUNT.labels(method=request.method, path=label).inc()

    level = logging.DEBUG if raw_path in QUIET_PATHS else logging.INFO
    if response.status_code >= 500:
        level = logging.ERROR
    elif response.status_code >= 400:
        level = max(level, logging.WARNING)
    logger.log(
        level,
        "request completed",
        extra={
            "method": request.method,
            "path": raw_path,
            "status": response.status_code,
            "duration_ms": round(duration * 1000, 2),
        },
    )
    return response


@app.get("/")
async def root():
    return {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": APP_VERSION,
    }


@app.get("/health")
async def health():
    if _shutting_down:
        return Response(
            content=json.dumps({"status": "shutting_down"}),
            status_code=503,
            media_type="application/json",
        )
    return {"status": "healthy"}


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=PORT, log_config=None)
