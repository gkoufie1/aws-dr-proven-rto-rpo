"""Grades a drill and writes the evidence record.

Gathers: probe samples (S3), runbook timestamps (DR state table), FIS
experiment timing (primary region), which acknowledged writes actually
survived in the DR region (Aurora via Data API, DynamoDB replica), and
replication lag just before the fault. Then computes RTO/RPO and stores
drills/<run_id>/result.json.
"""

import json
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.config import Config

import rto_rpo

EVIDENCE_BUCKET = os.environ["EVIDENCE_BUCKET"]
STATE_TABLE = os.environ["STATE_TABLE"]
LEDGER_TABLE = os.environ["LEDGER_TABLE_NAME"]
DB_CLUSTER_ARN = os.environ["DB_CLUSTER_ARN"]
DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
DB_NAME = os.environ["DB_NAME"]
PRIMARY_REGION = os.environ["PRIMARY_REGION"]
SECONDARY_REGION = os.environ["SECONDARY_REGION"]
SECONDARY_CLUSTER_ID = os.environ["SECONDARY_CLUSTER_ID"]
RTO_TARGET = float(os.environ["RTO_TARGET_SECONDS"])
RPO_TARGET = float(os.environ["RPO_TARGET_SECONDS"])
FAULT_DESCRIPTION = os.environ.get("FAULT_DESCRIPTION", "")

_cfg = Config(connect_timeout=3, read_timeout=10, retries={"max_attempts": 3, "mode": "standard"})
_s3 = boto3.client("s3", config=_cfg)
_ddb = boto3.client("dynamodb", config=_cfg)
_rds = boto3.client("rds-data", config=_cfg)
_cw = boto3.client("cloudwatch", config=_cfg)
_cw_primary = boto3.client("cloudwatch", region_name=PRIMARY_REGION, config=_cfg)
_fis = boto3.client("fis", region_name=PRIMARY_REGION, config=_cfg)


def load_samples(key):
    body = _s3.get_object(Bucket=EVIDENCE_BUCKET, Key=key)["Body"].read().decode()
    return [json.loads(line) for line in body.splitlines() if line.strip()]


def runbook_timeline():
    item = _ddb.get_item(TableName=STATE_TABLE, Key={"pk": {"S": "failover"}}, ConsistentRead=True).get("Item", {})
    return {k: v.get("S") for k, v in item.items() if "S" in v}


def experiment_info(experiment_id):
    if not experiment_id:
        return {}, None
    try:
        exp = _fis.get_experiment(id=experiment_id)["experiment"]
    except Exception as exc:  # primary region may be the thing that is broken
        return {"id": experiment_id, "error": type(exc).__name__}, None
    actions = {
        name: {
            "status": a.get("state", {}).get("status"),
            "start_time": a["startTime"].isoformat() if a.get("startTime") else None,
            "end_time": a["endTime"].isoformat() if a.get("endTime") else None,
        }
        for name, a in exp.get("actions", {}).items()
    }
    fault_start = exp["actions"].get("fail-primary-api", {}).get("startTime") or exp.get("startTime")
    info = {
        "id": experiment_id,
        "template_id": exp.get("experimentTemplateId"),
        "status": exp.get("state", {}).get("status"),
        "start_time": exp["startTime"].isoformat() if exp.get("startTime") else None,
        "actions": actions,
    }
    return info, fault_start.timestamp() if fault_start else None


def surviving_aurora(run_id):
    """Acknowledged writes present on the (now-promoted) DR cluster."""
    try:
        res = _rds.execute_statement(
            resourceArn=DB_CLUSTER_ARN,
            secretArn=DB_SECRET_ARN,
            database=DB_NAME,
            sql="SELECT seq FROM orders WHERE run_id = :run_id",
            parameters=[{"name": "run_id", "value": {"stringValue": run_id}}],
        )
    except Exception as exc:
        print(json.dumps({"event": "aurora_unreadable", "error": f"{type(exc).__name__}: {exc}"}))
        return None
    return {rec[0]["longValue"] for rec in res.get("records", [])}


def surviving_dynamodb(run_id):
    """Acknowledged writes present in the DR-region replica (local read)."""
    seqs, kwargs = set(), {
        "TableName": LEDGER_TABLE,
        "KeyConditionExpression": "pk = :pk",
        "ExpressionAttributeValues": {":pk": {"S": f"run#{run_id}"}},
        "ProjectionExpression": "sk",
        "ConsistentRead": True,
    }
    try:
        while True:
            page = _ddb.query(**kwargs)
            seqs.update(int(i["sk"]["S"]) for i in page.get("Items", []))
            if "LastEvaluatedKey" not in page:
                return seqs
            kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    except Exception as exc:
        print(json.dumps({"event": "dynamodb_unreadable", "error": f"{type(exc).__name__}: {exc}"}))
        return None


def _max_metric(client, namespace, name, dims, start, end):
    try:
        res = client.get_metric_data(
            MetricDataQueries=[{
                "Id": "m",
                "MetricStat": {
                    "Metric": {"Namespace": namespace, "MetricName": name, "Dimensions": dims},
                    "Period": 60,
                    "Stat": "Maximum",
                },
            }],
            StartTime=start,
            EndTime=end,
        )
        values = res["MetricDataResults"][0].get("Values", [])
        return max(values) if values else None
    except Exception:
        return None


def replication_lag(outage_start_iso):
    """Replication lag in the 5 minutes before the outage: the theoretical
    exposure, reported alongside the measured loss."""
    if not outage_start_iso:
        return {}
    end = datetime.fromisoformat(outage_start_iso.replace("Z", "+00:00")) + timedelta(minutes=1)
    start = end - timedelta(minutes=6)
    return {
        "aurora_replication_lag_ms_max": _max_metric(
            _cw, "AWS/RDS", "AuroraGlobalDBReplicationLag",
            [{"Name": "DBClusterIdentifier", "Value": SECONDARY_CLUSTER_ID}], start, end),
        "aurora_rpo_lag_ms_max": _max_metric(
            _cw, "AWS/RDS", "AuroraGlobalDBRPOLag",
            [{"Name": "DBClusterIdentifier", "Value": SECONDARY_CLUSTER_ID}], start, end),
        "dynamodb_replication_latency_ms_max": _max_metric(
            _cw_primary, "AWS/DynamoDB", "ReplicationLatency",
            [{"Name": "TableName", "Value": LEDGER_TABLE}, {"Name": "ReceivingRegion", "Value": SECONDARY_REGION}], start, end),
    }


def handler(event, context):
    run_id = event["run_id"]
    probe = event["probe"]
    samples = load_samples(probe["samples_key"])
    timeline = runbook_timeline()
    experiment, fault_injected_at = experiment_info(event.get("experiment_id"))

    result = rto_rpo.compute(
        samples,
        primary_region=PRIMARY_REGION,
        secondary_region=SECONDARY_REGION,
        surviving={"aurora": surviving_aurora(run_id), "dynamodb": surviving_dynamodb(run_id)},
        timeline=timeline,
        fault_injected_at=fault_injected_at,
        runbook_state=event.get("dr_state"),
        rto_target=RTO_TARGET,
        rpo_target=RPO_TARGET,
    )

    evidence = {
        "schema_version": 1,
        "run_id": run_id,
        "scenario": "region-impairment",
        "fault": FAULT_DESCRIPTION,
        "regions": {"primary": PRIMARY_REGION, "secondary": SECONDARY_REGION},
        "targets": {"rto_seconds": RTO_TARGET, "rpo_seconds": RPO_TARGET},
        "drill_started_at": event.get("started_at"),
        "generated_at": rto_rpo.iso(datetime.now(timezone.utc).timestamp()),
        "probe_stop_reason": probe.get("stop_reason"),
        "runbook": {
            "final_state": event.get("dr_state"),
            "trigger_reason": timeline.get("trigger_reason"),
            "execution_id": timeline.get("execution_id"),
            "last_error": timeline.get("last_error"),
        },
        "experiment": experiment,
        "replication_lag_before_outage": replication_lag(result["timestamps"].get("outage_start")),
        **result,
    }

    key = f"drills/{run_id}/result.json"
    _s3.put_object(Bucket=EVIDENCE_BUCKET, Key=key, Body=json.dumps(evidence, indent=2, default=str).encode(),
                   ContentType="application/json")
    print(json.dumps({"event": "drill_graded", "run_id": run_id, "verdict": result["verdict"],
                      "rto_seconds": result["rto_seconds"], "rpo_seconds": result["rpo_seconds"],
                      "reasons": result["reasons"]}))

    return {
        "verdict": result["verdict"],
        "evidence_key": key,
        "rto_seconds": result["rto_seconds"],
        "rpo_seconds": result["rpo_seconds"],
        "reasons": result["reasons"],
    }
