"""Cross-region helper for the DR-region state machines.

Step Functions SDK integrations call the service in the state machine's own
region; FIS experiments live in the primary region, and health verification
should come from outside AWS's control plane (a real HTTPS request). This
function covers both.
"""

import json
import os
import urllib.error
import urllib.request
import uuid

import boto3

PRIMARY_REGION = os.environ["PRIMARY_REGION"]
FIS_TEMPLATE_ID = os.environ["FIS_TEMPLATE_ID"]

_fis = boto3.client("fis", region_name=PRIMARY_REGION)

ACTIVE_STATES = {"pending", "initiating", "running"}


def check_health(url):
    try:
        req = urllib.request.Request(url, headers={"user-agent": "dr-proof-verify/1.0", "cache-control": "no-cache"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.loads(resp.read() or b"{}")
            return {"healthy": resp.status == 200, "status": resp.status, "region": body.get("region")}
    except urllib.error.HTTPError as exc:
        return {"healthy": False, "status": exc.code}
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {"healthy": False, "status": None, "error": type(exc).__name__}


def start_experiment(run_id):
    exp = _fis.start_experiment(
        clientToken=str(uuid.uuid4()),
        experimentTemplateId=FIS_TEMPLATE_ID,
        tags={"run_id": run_id},
    )["experiment"]
    return {
        "experiment_id": exp["id"],
        "state": exp["state"]["status"],
        "start_time": exp.get("startTime").isoformat() if exp.get("startTime") else None,
    }


def stop_experiments(run_id):
    stopped, kwargs = [], {"experimentTemplateId": FIS_TEMPLATE_ID, "maxResults": 100}
    while True:
        page = _fis.list_experiments(**kwargs)
        for exp in page.get("experiments", []):
            if exp.get("tags", {}).get("run_id") != run_id:
                continue
            if exp["state"]["status"] in ACTIVE_STATES:
                try:
                    _fis.stop_experiment(id=exp["id"])
                    stopped.append(exp["id"])
                except _fis.exceptions.ConflictException:
                    pass  # finished between list and stop
        if not page.get("nextToken"):
            return {"stopped": stopped}
        kwargs["nextToken"] = page["nextToken"]


def handler(event, context):
    action = event.get("action")
    if action == "check_health":
        return check_health(event["url"])
    if action == "start_experiment":
        return start_experiment(event["run_id"])
    if action == "stop_experiments":
        return stop_experiments(event["run_id"])
    raise ValueError(f"unknown action: {action}")
