"""DR-region watchdog: decides when the primary is down.

Runs every minute and probes the primary's region-pinned /health endpoint
every few seconds for ~50 s, so detection is effectively continuous. After
N consecutive failures it starts the failover runbook. It never fails over
itself - the runbook owns the lock and the decision record.

Why not a Route 53 health-check alarm? Those metrics and alarms live only in
us-east-1. Automation that depends on the primary region to announce its own
failure is not DR automation.
"""

import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3

STATE_TABLE = os.environ["STATE_TABLE"]
FAILOVER_SM_ARN = os.environ["FAILOVER_STATE_MACHINE_ARN"]
PRIMARY_HEALTH_URL = os.environ["PRIMARY_HEALTH_URL"]
FAILURE_THRESHOLD = int(os.environ.get("FAILURE_THRESHOLD", "3"))
PROBE_INTERVAL = float(os.environ.get("PROBE_INTERVAL_SECONDS", "5"))
RUN_SECONDS = float(os.environ.get("RUN_SECONDS", "50"))
PROBE_TIMEOUT = 3
PROJECT = STATE_TABLE.removesuffix("-dr-state")

_ddb = boto3.client("dynamodb")
_sfn = boto3.client("stepfunctions")


def _now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _emit(healthy, latency_ms):
    # CloudWatch Embedded Metric Format: a log line becomes a metric, no API call.
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": "DRProof",
                "Dimensions": [["Project"]],
                "Metrics": [{"Name": "PrimaryHealthy"}, {"Name": "PrimaryProbeLatency", "Unit": "Milliseconds"}],
            }],
        },
        "Project": PROJECT,
        "PrimaryHealthy": 1 if healthy else 0,
        "PrimaryProbeLatency": latency_ms,
    }))


def probe():
    started = time.monotonic()
    try:
        req = urllib.request.Request(PRIMARY_HEALTH_URL, headers={"user-agent": "dr-proof-watchdog/1.0"})
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT) as resp:
            ok = resp.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        ok = False
    latency_ms = int((time.monotonic() - started) * 1000)
    _emit(ok, latency_ms)
    return ok


def current_state():
    item = _ddb.get_item(TableName=STATE_TABLE, Key={"pk": {"S": "failover"}}, ConsistentRead=True).get("Item", {})
    return item.get("state", {}).get("S", "PRIMARY_ACTIVE")


def trigger_failover(first_failure_at, failures):
    name = "auto-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    payload = {
        "reason": f"watchdog: {failures} consecutive failed probes of primary /health",
        "first_failure_at": first_failure_at,
        "detected_at": _now_iso(),
    }
    try:
        _sfn.start_execution(stateMachineArn=FAILOVER_SM_ARN, name=name, input=json.dumps(payload))
    except _sfn.exceptions.ExecutionAlreadyExists:
        pass
    print(json.dumps({"event": "failover_triggered", "execution": name, **payload}))


def handler(event, context):
    state = current_state()
    if state != "PRIMARY_ACTIVE":
        # Failed over, failing back, or awaiting a human: probing the primary
        # now would only re-trigger a runbook that is already decided.
        print(json.dumps({"event": "skipped", "state": state}))
        return {"skipped": state}

    deadline = time.monotonic() + RUN_SECONDS
    failures, first_failure_at = 0, None

    while time.monotonic() < deadline and context.get_remaining_time_in_millis() > (PROBE_TIMEOUT + 3) * 1000:
        if probe():
            failures, first_failure_at = 0, None
        else:
            failures += 1
            first_failure_at = first_failure_at or _now_iso()
            if failures >= FAILURE_THRESHOLD:
                trigger_failover(first_failure_at, failures)
                return {"triggered": True}
        time.sleep(PROBE_INTERVAL)

    return {"triggered": False}
