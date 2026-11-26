"""notification: event-driven worker consuming `order-events` from Azure Service Bus.

* Authenticates with Entra Workload Identity (DefaultAzureCredential picks up
  the federated token the AKS webhook mounts) - no connection strings.
* Scaled 0..N by KEDA on subscription backlog (see gitops values).
* Messages are completed only after successful handling; failures are
  abandoned and land in the dead-letter queue after maxDeliveryCount.
* Health/metrics on :8080 like every other service, so the platform treats
  workers and APIs the same way.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os

from fastapi import FastAPI, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest

log = logging.getLogger("notification")
logging.basicConfig(level=logging.INFO, format='{"level":"%(levelname)s","msg":"%(message)s"}')

NAMESPACE = os.getenv("SERVICEBUS_FQDN")  # e.g. sb-shopsphere-prod.servicebus.windows.net
TOPIC = os.getenv("SERVICEBUS_TOPIC", "order-events")
SUBSCRIPTION = os.getenv("SERVICEBUS_SUBSCRIPTION", "notification")

PROCESSED = Counter("notification_messages_total", "Messages processed", ["result"])


def render_email(event: dict) -> str:
    """Pure function -> easy to unit test."""
    return (
        f"Hi! Your order {event['orderId']} is {event.get('status', 'confirmed')}. "
        f"Total: {event.get('totalCents', 0) / 100:.2f} {event.get('currency', 'EUR')}."
    )


async def consume(state: dict) -> None:
    from azure.identity.aio import DefaultAzureCredential
    from azure.servicebus.aio import ServiceBusClient

    async with DefaultAzureCredential() as cred, ServiceBusClient(NAMESPACE, cred) as sb:
        receiver = sb.get_subscription_receiver(topic_name=TOPIC, subscription_name=SUBSCRIPTION, max_wait_time=20)
        async with receiver:
            state["running"] = True
            while True:
                for msg in await receiver.receive_messages(max_message_count=20, max_wait_time=5):
                    try:
                        event = json.loads(str(msg))
                        log.info(render_email(event))  # production: send via Azure Communication Services
                        await receiver.complete_message(msg)
                        PROCESSED.labels("ok").inc()
                    except Exception as exc:  # noqa: BLE001
                        log.error(f"failed: {exc}")
                        await receiver.abandon_message(msg)
                        PROCESSED.labels("error").inc()


def create_app(start_consumer: bool = NAMESPACE is not None) -> FastAPI:
    state = {"running": not start_consumer}  # without Service Bus (local/tests) we are "ready"

    @contextlib.asynccontextmanager
    async def lifespan(_app: FastAPI):
        task = asyncio.create_task(consume(state)) if start_consumer else None
        yield
        if task:
            task.cancel()  # SIGTERM: stop receiving; un-completed messages are redelivered

    app = FastAPI(title="notification", lifespan=lifespan)

    @app.get("/healthz")
    async def healthz():
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz(response: Response):
        response.status_code = 200 if state["running"] else 503
        return {"consuming": state["running"]}

    @app.get("/metrics")
    async def metrics():
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    return app


app = create_app()
