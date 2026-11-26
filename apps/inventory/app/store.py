"""Inventory storage: PostgreSQL (Azure Flexible Server) or in-memory for tests.

Reservations use a single UPDATE ... WHERE available >= qty per line inside one
transaction, so two concurrent checkouts can never oversell the last unit.
"""

from __future__ import annotations

import os
import threading
from typing import Protocol

SEED = {
    "sku-1001": 40,
    "sku-1002": 25,
    "sku-1003": 100,
    "sku-1004": 15,
    "sku-1005": 60,
    "sku-1006": 8,
}


class InsufficientStock(Exception):
    def __init__(self, sku: str):
        super().__init__(sku)
        self.sku = sku


class Store(Protocol):
    def available(self, sku: str) -> int | None: ...
    def reserve(self, order_id: str, items: list[tuple[str, int]]) -> None: ...
    def healthy(self) -> bool: ...


class MemoryStore:
    def __init__(self) -> None:
        self._stock = dict(SEED)
        self._lock = threading.Lock()

    def available(self, sku: str) -> int | None:
        return self._stock.get(sku)

    def reserve(self, order_id: str, items: list[tuple[str, int]]) -> None:
        with self._lock:
            for sku, qty in items:
                if self._stock.get(sku, 0) < qty:
                    raise InsufficientStock(sku)
            for sku, qty in items:
                self._stock[sku] -= qty

    def healthy(self) -> bool:
        return True


class PostgresStore:
    def __init__(self, dsn: str) -> None:
        from psycopg_pool import ConnectionPool

        self._pool = ConnectionPool(dsn, min_size=1, max_size=10, open=True)

    def available(self, sku: str) -> int | None:
        with self._pool.connection() as conn:
            row = conn.execute("SELECT available FROM stock WHERE sku = %s", (sku,)).fetchone()
            return row[0] if row else None

    def reserve(self, order_id: str, items: list[tuple[str, int]]) -> None:
        with self._pool.connection() as conn, conn.transaction():
            for sku, qty in items:
                cur = conn.execute(
                    "UPDATE stock SET available = available - %s WHERE sku = %s AND available >= %s",
                    (qty, sku, qty),
                )
                if cur.rowcount != 1:
                    raise InsufficientStock(sku)  # rolls back the whole transaction
                conn.execute(
                    "INSERT INTO reservations (order_id, sku, quantity) VALUES (%s, %s, %s)",
                    (order_id, sku, qty),
                )

    def healthy(self) -> bool:
        try:
            with self._pool.connection() as conn:
                conn.execute("SELECT 1")
            return True
        except Exception:  # noqa: BLE001
            return False


def make_store() -> Store:
    dsn = os.getenv("DATABASE_URL")
    return PostgresStore(dsn) if dsn else MemoryStore()
