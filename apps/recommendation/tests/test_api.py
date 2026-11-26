import httpx
from fastapi.testclient import TestClient

from app.main import create_app

PRODUCTS = [
    {"id": "a", "category": "apparel"},
    {"id": "b", "category": "apparel"},
    {"id": "c", "category": "bags"},
]


def test_same_category_first():
    transport = httpx.MockTransport(lambda req: httpx.Response(200, json=PRODUCTS))
    body = TestClient(create_app(transport)).get("/api/recommendations?productId=a&limit=2").json()
    assert body == {"productId": "a", "recommendations": ["b", "c"], "source": "catalog"}


def test_falls_back_when_catalog_down():
    transport = httpx.MockTransport(lambda req: httpx.Response(503))
    body = TestClient(create_app(transport)).get("/api/recommendations?productId=a").json()
    assert body["source"] == "fallback"
