from fastapi.testclient import TestClient

from app.main import create_app, render_email


def test_render_email():
    text = render_email({"orderId": "o-42", "status": "paid", "totalCents": 12345, "currency": "EUR"})
    assert "o-42" in text and "123.45 EUR" in text


def test_ready_without_service_bus():
    with TestClient(create_app(start_consumer=False)) as c:
        assert c.get("/readyz").status_code == 200
