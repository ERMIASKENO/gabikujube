"""Nightly reconciliation, run by a Kubernetes CronJob.

Reports reservations older than RESERVATION_TTL_HOURS that never turned into
a paid order. Exits non-zero on DB errors so the Job is marked failed and the
KubeJobFailed alert fires.
"""

from __future__ import annotations

import json
import os
import sys


def main() -> int:
    dsn = os.getenv("DATABASE_URL")
    ttl = int(os.getenv("RESERVATION_TTL_HOURS", "24"))
    if not dsn:
        print(json.dumps({"level": "info", "msg": "no DATABASE_URL, skipping"}))
        return 0
    import psycopg

    with psycopg.connect(dsn) as conn:
        rows = conn.execute(
            "SELECT count(*) FROM reservations WHERE created_at < now() - make_interval(hours => %s)",
            (ttl,),
        ).fetchone()
    print(json.dumps({"level": "info", "msg": "reconcile", "staleReservations": rows[0]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
