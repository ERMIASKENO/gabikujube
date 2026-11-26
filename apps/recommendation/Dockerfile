# syntax=docker/dockerfile:1.7
# Multi-stage Python image using uv for fast, lockfile-exact installs.
# Builder resolves into /opt/venv; runtime copies only the venv + app code.
ARG PYTHON_VERSION=3.13

FROM python:${PYTHON_VERSION}-slim AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PROJECT_ENVIRONMENT=/opt/venv UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen --no-dev

FROM builder AS test
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen
COPY . .
RUN /opt/venv/bin/ruff check . && /opt/venv/bin/pytest -q

FROM python:${PYTHON_VERSION}-slim AS runtime
ARG VERSION=dev
LABEL org.opencontainers.image.title="recommendation" org.opencontainers.image.version="${VERSION}"
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 APP_VERSION=${VERSION}
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY app ./app
USER 10001:10001
EXPOSE 8080
# uvicorn handles SIGTERM gracefully; --timeout-graceful-shutdown bounds the drain
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--timeout-graceful-shutdown", "20", "--no-access-log"]
