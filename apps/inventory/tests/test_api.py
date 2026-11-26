from fastapi.testclient import TestClient

from app.main import create_app
from app.store import MemoryStore


def client() -> TestClient:
    return TestClient(create_app(MemoryStore()))


def test_reserve_decrements_stock():
    c = client()
    before = c.get("/api/inventory/sku-1006").json()["available"]
    r = c.post("/api/inventory/reserve", json={"orderId": "o1", "items": [{"productId": "sku-1006", "quantity": 2}]})
    assert r.status_code == 200
    assert c.get("/api/inventory/sku-1006").json()["available"] == before - 2


def test_reserve_is_all_or_nothing():
    c = client()
    r = c.post(
        "/api/inventory/reserve",
        json={"orderId": "o2", "items": [{"productId": "sku-1001", "quantity": 1}, {"productId": "sku-1006", "quantity": 99}]},
    )
    assert r.status_code == 409
    # first line must not have been decremented
    assert c.get("/api/inventory/sku-1001").json()["available"] == 40


def test_metrics_exposed():
    c = client()
    c.get("/healthz")
    assert "http_requests_total" in c.get("/metrics").text
