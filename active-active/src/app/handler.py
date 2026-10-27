"""Regional order API for the active-active stack, deployed identically in
both regions, and both regions take writes all the time.

Writes go to this region's endpoint of a multi-Region Aurora DSQL cluster.
DSQL commits synchronously across the two peered regions (plus a witness), so
a 201 here means the row is durable in both regions before the client hears
about it. That is the claim the drill tests: RPO = 0, with no promotion step.

/health returns 200 only when this region can run a query against DSQL.
"""

import json
import logging
import os
import re
import time

from dsql_conn import DsqlConnection

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ["AWS_REGION"]
DSQL_ENDPOINT = os.environ["DSQL_ENDPOINT"]
DB_USER = os.environ.get("DB_USER", "app")

RUN_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,80}$")

_db = DsqlConnection(DSQL_ENDPOINT, REGION, DB_USER)


class Unavailable(Exception):
    """This region cannot currently serve the request."""


def _sql(sql, retry=True, **params):
    try:
        return _db.run(sql, retry=retry, **params)
    except Exception as exc:
        raise Unavailable(f"dsql: {type(exc).__name__}: {exc}") from exc


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            "cache-control": "no-store",
            "x-served-by-region": REGION,
        },
        "body": json.dumps({**body, "region": REGION}),
    }


def health():
    started = time.monotonic()
    _sql("SELECT 1")
    return _response(200, {"status": "ok", "writable": True, "check_ms": int((time.monotonic() - started) * 1000)})


def create_order(event):
    try:
        body = json.loads(event.get("body") or "{}")
        run_id = str(body["run_id"])
        client = str(body.get("client", "unknown"))
        seq = int(body["seq"])
        client_ts = float(body.get("client_ts", time.time()))
    except (ValueError, KeyError, TypeError):
        return _response(400, {"error": "body must include run_id (string) and seq (int)"})
    if not RUN_ID_RE.match(run_id) or not RUN_ID_RE.match(client) or seq < 0:
        return _response(400, {"error": "invalid run_id, client or seq"})

    started = time.monotonic()
    # Idempotent, so the connection helper may retry it on a fresh connection.
    _sql(
        "INSERT INTO app.orders (run_id, client, seq, region, client_ts) "
        "VALUES (:run_id, :client, :seq, :region, :client_ts) "
        "ON CONFLICT (run_id, client, seq) DO NOTHING",
        run_id=run_id,
        client=client,
        seq=seq,
        region=REGION,
        client_ts=client_ts,
    )
    commit_ms = round((time.monotonic() - started) * 1000, 1)
    return _response(201, {"committed": True, "run_id": run_id, "seq": seq, "commit_ms": commit_ms})


def list_orders(event):
    qs = event.get("queryStringParameters") or {}
    run_id = qs.get("run_id", "")
    if not RUN_ID_RE.match(run_id):
        return _response(400, {"error": "run_id query parameter required"})
    rows = _sql(
        "SELECT client, count(*), max(seq) FROM app.orders WHERE run_id = :run_id GROUP BY client",
        run_id=run_id,
    )
    return _response(200, {"run_id": run_id, "clients": {c: {"count": n, "max_seq": m} for c, n, m in rows}})


ROUTES = {
    "GET /health": lambda event: health(),
    "POST /orders": create_order,
    "GET /orders": list_orders,
}


def handler(event, context):
    http = event.get("requestContext", {}).get("http", {})
    route = f"{http.get('method', 'GET')} {event.get('rawPath', '/')}"
    fn = ROUTES.get(route)
    if fn is None:
        return _response(404, {"error": "not found"})
    try:
        return fn(event)
    except Unavailable as exc:
        logger.warning("unavailable route=%s detail=%s", route, exc)
        return _response(503, {"error": "unavailable", "writable": False})
