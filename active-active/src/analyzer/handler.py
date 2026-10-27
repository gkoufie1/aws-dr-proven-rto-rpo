"""Grades one active-active drill and writes result.json next to the samples.

Reads both clients' probe samples, the FIS experiment's real action times, and
reads every write back from EACH region's DSQL endpoint (as the read-only
`auditor` role) - so "zero data loss" is checked in both places, not assumed.
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3

import aa_metrics
from dsql_conn import DsqlConnection

logger = logging.getLogger()
logger.setLevel(logging.INFO)

EVIDENCE_BUCKET = os.environ["EVIDENCE_BUCKET"]
IMPAIRED_REGION = os.environ["IMPAIRED_REGION"]
FIS_ACTION_NAME = os.environ["FIS_ACTION_NAME"]
DSQL_ENDPOINTS = json.loads(os.environ["DSQL_ENDPOINTS"])  # {region: endpoint}
MAX_OUTAGE_TARGET = float(os.environ["MAX_OUTAGE_TARGET_SECONDS"])
FAULT_DESCRIPTION = os.environ.get("FAULT_DESCRIPTION", "")

_s3 = boto3.client("s3")
_fis = boto3.client("fis", region_name=IMPAIRED_REGION)


def load_samples(run_id, client):
    body = _s3.get_object(Bucket=EVIDENCE_BUCKET, Key=f"drills/{run_id}/samples-{client}.jsonl")["Body"].read()
    return [json.loads(line) for line in body.decode().splitlines() if line.strip()]


def fault_window(experiment_id):
    exp = _fis.get_experiment(id=experiment_id)["experiment"]
    action = exp.get("actions", {}).get(FIS_ACTION_NAME, {})
    start, end = action.get("startTime"), action.get("endTime")
    return {
        "start": start.timestamp() if start else None,
        "end": end.timestamp() if end else None,
        "experiment_id": experiment_id,
        "experiment_state": exp["state"]["status"],
        "action_state": action.get("state", {}).get("status"),
    }


def read_back(run_id):
    persisted = {}
    for region, endpoint in DSQL_ENDPOINTS.items():
        db = DsqlConnection(endpoint, region, "auditor", timeout=10)
        try:
            rows = db.run("SELECT client, seq FROM app.orders WHERE run_id = :run_id", run_id=run_id)
            by_client = {}
            for client, seq in rows:
                by_client.setdefault(client, set()).add(int(seq))
            persisted[region] = by_client
        except Exception:
            logger.exception("could not read back writes from %s", region)
            persisted[region] = None
        finally:
            db.close()
    return persisted


def handler(event, context):
    run_id = event["run_id"]
    clients = {c: load_samples(run_id, c) for c in event["clients"]}
    fault = fault_window(event["experiment_id"])
    persisted = read_back(run_id)

    result = aa_metrics.compute(
        clients=clients,
        fault=fault,
        persisted=persisted,
        impaired_region=IMPAIRED_REGION,
        targets={"max_outage_seconds": MAX_OUTAGE_TARGET},
    )
    result.update({
        "run_id": run_id,
        "architecture": "active-active",
        "drill_started_at": min((s[0]["t_send"] for s in clients.values() if s), default=None),
        "graded_at": datetime.now(timezone.utc).isoformat(),
        "fault_description": FAULT_DESCRIPTION,
        "experiment": {k: fault[k] for k in ("experiment_id", "experiment_state", "action_state")},
    })

    _s3.put_object(
        Bucket=EVIDENCE_BUCKET,
        Key=f"drills/{run_id}/result.json",
        Body=json.dumps(result, indent=2, default=str).encode(),
        ContentType="application/json",
    )
    logger.info("verdict %s: %s", result["verdict"], result["reasons"])
    return {"verdict": result["verdict"], "reasons": result["reasons"], "headline": result["headline"]}
