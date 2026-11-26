"""inventory: stock lookup and atomic reservation (FastAPI)."""

from __future__ import annotations

import os
import time

from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

from .store import InsufficientStock, Store, make_store

REQUESTS = Counter("http_requests_total", "HTTP requests", ["route", "method", "code"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP latency", ["route", "method"])
RESERVATIONS = Counter("inventory_reservations_total", "Reservations", ["result"])


class Line(BaseModel):
    productId: str
    quantity: int = Field(ge=1, le=99)


class ReserveRequest(BaseModel):
    orderId: str
    items: list[Line] = Field(min_length=1)


def create_app(store: Store | None = None) -> FastAPI:
    app = FastAPI(title="inventory", version=os.getenv("APP_VERSION", "dev"))
    app.state.store = store or make_store()

    @app.middleware("http")
    async def metrics_middleware(request: Request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        route = request.scope.get("route")
        path = getattr(route, "path", "unmatched")
        REQUESTS.labels(path, request.method, str(response.status_code)).inc()
        LATENCY.labels(path, request.method).observe(time.perf_counter() - start)
        return response

    @app.get("/healthz")
    def healthz():
        return {"status": "ok"}

    @app.get("/readyz")
    def readyz(response: Response):
        ok = app.state.store.healthy()
        response.status_code = 200 if ok else 503
        return {"ready": ok}

    @app.get("/metrics")
    def metrics():
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.get("/api/inventory/{sku}")
    def get_stock(sku: str):
        qty = app.state.store.available(sku)
        if qty is None:
            raise HTTPException(404, "unknown sku")
        return {"sku": sku, "available": qty}

    @app.post("/api/inventory/reserve")
    def reserve(req: ReserveRequest):
        try:
            app.state.store.reserve(req.orderId, [(i.productId, i.quantity) for i in req.items])
        except InsufficientStock as e:
            RESERVATIONS.labels("insufficient").inc()
            raise HTTPException(409, f"insufficient stock for {e.sku}") from e
        RESERVATIONS.labels("ok").inc()
        return {"orderId": req.orderId, "status": "reserved"}

    return app


app = create_app()
