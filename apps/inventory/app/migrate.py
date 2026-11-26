"""Idempotent schema migration + seed.

Runs as an Argo CD PreSync hook Job (see the Helm chart's migration job), so
the schema is updated BEFORE new pods roll out, and a failed migration blocks
the sync instead of crash-looping the new ReplicaSet. Migrations must be
backward compatible (expand -> migrate -> contract) because old pods keep
serving during a canary.
"""

from __future__ import annotations

import os
import sys

from .store import SEED

DDL = [
    """CREATE TABLE IF NOT EXISTS stock (
           sku        TEXT PRIMARY KEY,
           available  INTEGER NOT NULL CHECK (available >= 0),
           updated_at TIMESTAMPTZ NOT NULL DEFAULT now())""",
    """CREATE TABLE IF NOT EXISTS reservations (
           id         BIGSERIAL PRIMARY KEY,
           order_id   TEXT NOT NULL,
           sku        TEXT NOT NULL REFERENCES stock(sku),
           quantity   INTEGER NOT NULL,
           created_at TIMESTAMPTZ NOT NULL DEFAULT now())""",
    "CREATE INDEX IF NOT EXISTS reservations_order_idx ON reservations(order_id)",
]


def main() -> int:
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        print("DATABASE_URL not set; nothing to migrate")
        return 0
    import psycopg

    with psycopg.connect(dsn) as conn, conn.transaction():
        for stmt in DDL:
            conn.execute(stmt)
        for sku, qty in SEED.items():
            conn.execute(
                "INSERT INTO stock (sku, available) VALUES (%s, %s) ON CONFLICT (sku) DO NOTHING",
                (sku, qty),
            )
    print("migration complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
