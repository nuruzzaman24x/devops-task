# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Stage 1: builder - install dependencies into an isolated venv
# ---------------------------------------------------------------------------
# Base pinned by tag AND digest (tag for readability, digest for immutability)
FROM python:3.12-alpine3.22@sha256:a190708a2dec1bd18b1decb539f8e8f5407abaa9bf39cacda583f7f8c11db322 AS builder

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY app/requirements.txt .
RUN pip install --no-cache-dir --upgrade pip==24.3.1 \
    && pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: final - minimal Alpine runtime, non-root, no build tools
# ---------------------------------------------------------------------------
FROM python:3.12-alpine3.22@sha256:a190708a2dec1bd18b1decb539f8e8f5407abaa9bf39cacda583f7f8c11db322 AS final

LABEL org.opencontainers.image.title="devops-task-service" \
      org.opencontainers.image.description="Small web service for DevOps take-home assessment" \
      org.opencontainers.image.source="https://github.com/<org>/<repo>" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="candidate"

# Unprivileged, no-login user/group (Alpine/busybox syntax)
RUN addgroup -g 10001 appgroup \
    && adduser -D -H -u 10001 -G appgroup -s /sbin/nologin appuser

WORKDIR /app

# Only the venv with installed deps and the app code are copied
COPY --from=builder /opt/venv /opt/venv
COPY app/main.py /app/main.py

RUN chown -R appuser:appgroup /app

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    LOG_LEVEL=INFO \
    APP_ENV=production

ARG APP_VERSION=0.1.0
ENV APP_VERSION=${APP_VERSION}

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8080/health').status==200 else sys.exit(1)"]

ENTRYPOINT ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
