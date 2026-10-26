"""Regional order API, deployed identically in both regions.

Each write is committed to Aurora (system of record, via the RDS Data API)
and then to the DynamoDB global table. A write is only acknowledged (201,
committed=true) after both succeed, so the drill's RPO check compares
exactly what clients were told against what survived failover.

/health returns 200 only when this region can commit a write. On an Aurora
global secondary the Data API fails until the cluster is promoted, so the
health check - and therefore Route 53 failover - follows the writer.
"""

import json
import logging
import os
import re
import time

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ["AWS_REGION"]
REGION_ROLE = os.environ["REGION_ROLE"]
DB_CLUSTER_ARN = os.environ["DB_CLUSTER_ARN"]
DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
DB_NAME = os.environ["DB_NAME"]
TABLE_NAME = os.environ["TABLE_NAME"]

# Fail fast: a health check that hangs is worse than one that says no.
_cfg = Config(connect_timeout=2, read_timeout=5, retries={"max_attempts": 1, "mode": "standard"})
_rds = boto3.client("rds-data", config=_cfg)
_ddb = boto3.client("dynamodb", config=_cfg)

RUN_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,80}$")
LEDGER_TTL_SECONDS = 30 * 24 * 3600

SCHEMA = """
CREATE TABLE IF NOT EXISTS orders (
    run_id     text             NOT NULL,
    seq        bigint           NOT NULL,
    region     text             NOT NULL,
    client_ts  double precision,
    created_at timestamptz      NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, seq)
)
"""


class Unavailable(Exception):
    """This region cannot currently serve the request."""


def _sql(sql, params=None):
    try:
        return _rds.execute_statement(
            resourceArn=DB_CLUSTER_ARN,
            secretArn=DB_SECRET_ARN,
            database=DB_NAME,
            sql=sql,
            parameters=params or [],
        )
    except Exception as exc:  # Data API raises several distinct types; all mean "not writable here"
        raise Unavailable(f"aurora: {type(exc).__name__}: {exc}") from exc


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            "cache-control": "no-store",
            "x-served-by-region": REGION,
        },
        "body": json.dumps({**body, "region": REGION, "role": REGION_ROLE}),
    }


def health():
    started = time.monotonic()
    _sql("SELECT 1")
    try:
        _ddb.get_item(TableName=TABLE_NAME, Key={"pk": {"S": "health"}, "sk": {"S": "health"}})
    except Exception as exc:
        raise Unavailable(f"dynamodb: {type(exc).__name__}") from exc
    return _response(200, {"status": "ok", "writable": True, "check_ms": int((time.monotonic() - started) * 1000)})


def create_order(event):
    try:
        body = json.loads(event.get("body") or "{}")
        run_id = str(body["run_id"])
        seq = int(body["seq"])
        client_ts = float(body.get("client_ts", time.time()))
    except (ValueError, KeyError, TypeError):
        return _response(400, {"error": "body must include run_id (string) and seq (int)"})
    if not RUN_ID_RE.match(run_id) or seq < 0:
        return _response(400, {"error": "invalid run_id or seq"})

    _sql(
        "INSERT INTO orders (run_id, seq, region, client_ts) VALUES (:run_id, :seq, :region, :client_ts) "
        "ON CONFLICT (run_id, seq) DO NOTHING",
        [
            {"name": "run_id", "value": {"stringValue": run_id}},
            {"name": "seq", "value": {"longValue": seq}},
            {"name": "region", "value": {"stringValue": REGION}},
            {"name": "client_ts", "value": {"doubleValue": client_ts}},
        ],
    )

    try:
        _ddb.put_item(
            TableName=TABLE_NAME,
            Item={
                "pk": {"S": f"run#{run_id}"},
                "sk": {"S": f"{seq:08d}"},
                "region": {"S": REGION},
                "client_ts": {"N": repr(client_ts)},
                "expires_at": {"N": str(int(time.time()) + LEDGER_TTL_SECONDS)},
            },
        )
    except Exception as exc:
        # Aurora has it, DynamoDB does not: report not-committed so the client
        # (and the RPO check) never counts this as an acknowledged write.
        raise Unavailable(f"dynamodb: {type(exc).__name__}") from exc

    return _response(201, {"committed": True, "run_id": run_id, "seq": seq})


def list_orders(event):
    run_id = (event.get("queryStringParameters") or {}).get("run_id", "")
    if not RUN_ID_RE.match(run_id):
        return _response(400, {"error": "run_id query parameter required"})
    result = _sql(
        "SELECT count(*), coalesce(max(seq), -1) FROM orders WHERE run_id = :run_id",
        [{"name": "run_id", "value": {"stringValue": run_id}}],
    )
    count, max_seq = (col.get("longValue") for col in result["records"][0])
    return _response(200, {"run_id": run_id, "count": count, "max_seq": max_seq})


def migrate():
    # Fresh Serverless v2 clusters can take a moment before the Data API
    # accepts statements; retry within the function's 60 s timeout.
    deadline = time.monotonic() + 45
    while True:
        try:
            _sql(SCHEMA)
            logger.info("schema ready")
            return {"migrated": True}
        except Unavailable:
            if time.monotonic() > deadline:
                raise
            time.sleep(5)


ROUTES = {
    "GET /health": lambda event: health(),
    "POST /orders": create_order,
    "GET /orders": list_orders,
}


def handler(event, context):
    if event.get("action") == "migrate":
        return migrate()

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
