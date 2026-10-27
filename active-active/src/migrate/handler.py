"""One-off schema and access setup, invoked by Terraform after the clusters peer.

The only function allowed to connect as the DSQL `admin` role. It creates the
schema and two least-privilege database roles, and maps IAM roles onto them:

    app      SELECT, INSERT on app.orders   <- the regional API functions
    auditor  SELECT on app.orders           <- the drill analyzer

Every step is idempotent, so it is safe to run once per regional endpoint
(the second run is a no-op if DDL and grants replicated - and proves they did).
"""

import json
import logging
import os
import re
import time

from dsql_conn import DsqlConnection

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ARN_RE = re.compile(r"^arn:aws[a-z-]*:iam::\d{12}:role/[A-Za-z0-9+=,.@_/-]{1,128}$")
ROLE_RE = re.compile(r"^[a-z][a-z0-9_]{0,30}$")

SCHEMA = [
    "CREATE SCHEMA IF NOT EXISTS app",
    """CREATE TABLE IF NOT EXISTS app.orders (
        run_id     text             NOT NULL,
        client     text             NOT NULL,
        seq        bigint           NOT NULL,
        region     text             NOT NULL,
        client_ts  double precision,
        created_at timestamptz      NOT NULL DEFAULT now(),
        PRIMARY KEY (run_id, client, seq)
    )""",
]

GRANTS = {
    "app": ["GRANT USAGE ON SCHEMA app TO app", "GRANT SELECT, INSERT ON app.orders TO app"],
    "auditor": ["GRANT USAGE ON SCHEMA app TO auditor", "GRANT SELECT ON app.orders TO auditor"],
}


def migrate(db, mappings):
    for stmt in SCHEMA:
        db.run(stmt)

    existing_roles = {r[0] for r in db.run("SELECT rolname FROM pg_roles")}
    for role, grants in GRANTS.items():
        if role not in existing_roles:
            db.run(f"CREATE ROLE {role} WITH LOGIN")
        for stmt in grants:
            db.run(stmt)

    mapped = {(r[0], r[1]) for r in db.run("SELECT pg_role_name, arn FROM sys.iam_pg_role_mappings")}
    created = []
    for role, arns in mappings.items():
        if not ROLE_RE.match(role) or role not in GRANTS:
            raise ValueError(f"unexpected database role {role!r}")
        for arn in arns:
            if not ARN_RE.match(arn):
                raise ValueError(f"not an IAM role ARN: {arn!r}")
            if (role, arn) in mapped:
                continue
            # AWS IAM GRANT takes no bind parameters; both values are validated above.
            db.run(f"AWS IAM GRANT {role} TO '{arn}'")
            created.append(f"{role} <- {arn}")
    return created


def handler(event, context):
    endpoint, region = event["endpoint"], event["region"]
    mappings = json.loads(os.environ["ROLE_MAPPINGS"])
    db = DsqlConnection(endpoint, region, "admin", timeout=10)

    # A just-peered cluster can take a moment to accept connections.
    deadline = time.monotonic() + 240
    while True:
        try:
            created = migrate(db, mappings)
            break
        except Exception as exc:
            if time.monotonic() > deadline:
                raise
            logger.warning("migrate not ready yet: %s: %s", type(exc).__name__, exc)
            db.close()
            time.sleep(10)

    logger.info("schema ready on %s; new IAM mappings: %s", region, created)
    return {"region": region, "migrated": True, "new_mappings": created}
