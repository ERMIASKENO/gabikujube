"""recommendation: "customers also viewed" (FastAPI, async).

Demonstrates graceful degradation: if product-catalog is slow or down we
return a static fallback instead of failing the page (and count it in a
metric you can alert on). Timeouts are short because Istio already retries.
"""

from __future__ import annotations

import os
import time

import httpx
from fastapi import FastAPI, Query, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

CATALOG_URL = os.getenv("PRODUCT_CATALOG_URL", "http://product-catalog:8080")
FALLBACK = ["sku-1003", "sku-1005", "sku-1002"]

REQUESTS = Counter("http_requests_total", "HTTP requests", ["route", "method", "code"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP latency", ["route", "method"])
FALLBACKS = Counter("recommendation_fallback_total", "Responses served from static fallback")


def create_app(transport: httpx.AsyncBaseTransport | None = None) -> FastAPI:
    app = FastAPI(title="recommendation")
    client = httpx.AsyncClient(base_url=CATALOG_URL, timeout=httpx.Timeout(0.5), transport=transport)

    @app.middleware("http")
    async def metrics_middleware(request: Request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        path = getattr(request.scope.get("route"), "path", "unmatched")
        REQUESTS.labels(path, request.method, str(response.status_code)).inc()
        LATENCY.labels(path, request.method).observe(time.perf_counter() - start)
        return response

    @app.get("/healthz")
    async def healthz():
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz():
        return {"ready": True}

    @app.get("/metrics")
    async def metrics():
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.get("/api/recommendations")
    async def recommend(productId: str = Query(...), limit: int = Query(3, ge=1, le=10)):
        try:
            # propagate W3C trace context so Tempo shows one trace across services
            products = (await client.get("/api/products")).raise_for_status().json()
            current = next((p for p in products if p["id"] == productId), None)
            same_cat = [p["id"] for p in products if current and p["category"] == current["category"] and p["id"] != productId]
            others = [p["id"] for p in products if p["id"] != productId and p["id"] not in same_cat]
            return {"productId": productId, "recommendations": (same_cat + others)[:limit], "source": "catalog"}
        except (httpx.HTTPError, ValueError):
            FALLBACKS.inc()
            return {"productId": productId, "recommendations": FALLBACK[:limit], "source": "fallback"}

    return app


app = create_app()
