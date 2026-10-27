"""Synthetic client for active-active drills.

One instance runs near each serving region (us-east-2 for the east, us-west-2
for the west). Route 53 latency routing sends each client to its nearest
healthy region, exactly as it would a real user. Each instance writes once
per second through the public hostname for a fixed duration and records
exactly what it was told, including which region served each write.

Each request opens a fresh connection so DNS changes are honoured as soon as
the resolver's TTL allows. Every sample is also printed as a CloudWatch
Embedded Metric Format line, so the dashboard shows the client's view live.
"""

import json
import os
import time
import urllib.error
import urllib.request

import boto3

API_URL = os.environ["API_URL"].rstrip("/")
EVIDENCE_BUCKET = os.environ["EVIDENCE_BUCKET"]
CLIENT = os.environ["CLIENT_NAME"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "DrProof/ActiveActive")
REQUEST_TIMEOUT = 3

_s3 = boto3.client("s3")


def probe(run_id, seq):
    body = json.dumps({"run_id": run_id, "client": CLIENT, "seq": seq, "client_ts": time.time()}).encode()
    req = urllib.request.Request(
        f"{API_URL}/orders",
        data=body,
        method="POST",
        headers={"content-type": "application/json", "user-agent": f"dr-proof-aa-prober/{CLIENT}"},
    )
    sample = {"seq": seq, "t_send": time.time()}
    payload = {}
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            sample["status"] = resp.status
            payload = json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        sample["status"] = exc.code
        try:
            payload = json.loads(exc.read() or b"{}")
        except ValueError:
            payload = {}
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        sample["status"] = None
        sample["error"] = type(exc).__name__
    sample["t_recv"] = time.time()
    sample["region"] = payload.get("region")
    sample["commit_ms"] = payload.get("commit_ms")
    # Only an explicit commit counts towards the RPO promise.
    sample["acked"] = sample["status"] == 201 and payload.get("committed") is True
    return sample


def emit_metric(sample):
    served = sample["region"] or "none"
    print(json.dumps({
        "_aws": {
            "Timestamp": int(sample["t_send"] * 1000),
            "CloudWatchMetrics": [{
                "Namespace": METRIC_NAMESPACE,
                "Dimensions": [["Client"], ["Client", "ServedBy"]],
                "Metrics": [
                    {"Name": "WriteAcked", "Unit": "Count"},
                    {"Name": "WriteFailed", "Unit": "Count"},
                    {"Name": "WriteLatency", "Unit": "Milliseconds"},
                ],
            }],
        },
        "Client": CLIENT,
        "ServedBy": served,
        "WriteAcked": 1 if sample["acked"] else 0,
        "WriteFailed": 0 if sample["acked"] else 1,
        "WriteLatency": round((sample["t_recv"] - sample["t_send"]) * 1000, 1),
    }))


def handler(event, context):
    run_id = event["run_id"]
    duration = float(event.get("duration_seconds", 660))
    interval = float(event.get("interval_seconds", 1.0))

    samples, seq = [], 0
    t0 = time.time()
    stop_reason = "duration"
    while time.time() - t0 < duration:
        if context.get_remaining_time_in_millis() < 20_000:
            stop_reason = "lambda_deadline"
            break
        s = probe(run_id, seq)
        samples.append(s)
        emit_metric(s)
        seq += 1
        time.sleep(max(0.0, t0 + seq * interval - time.time()))

    key = f"drills/{run_id}/samples-{CLIENT}.jsonl"
    _s3.put_object(
        Bucket=EVIDENCE_BUCKET,
        Key=key,
        Body="\n".join(json.dumps(s, separators=(",", ":")) for s in samples).encode(),
        ContentType="application/x-ndjson",
    )
    return {
        "client": CLIENT,
        "samples_key": key,
        "sample_count": len(samples),
        "acked_count": sum(1 for s in samples if s["acked"]),
        "stop_reason": stop_reason,
        "started_at": t0,
        "ended_at": time.time(),
    }
