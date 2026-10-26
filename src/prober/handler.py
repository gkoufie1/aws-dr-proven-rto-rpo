"""Synthetic client for DR drills.

Sends one write per second to the public failover hostname - the same path a
real client uses, DNS caching and all - and records exactly what it was told.
Each request opens a fresh connection so DNS changes are honoured as soon as
the resolver's TTL allows (a pooled keep-alive connection would pin the old
region and overstate RTO).

Stops when: the service recovered (N consecutive acknowledged writes after a
failure), no fault was ever observed (inconclusive), or time runs out.
"""

import json
import os
import time
import urllib.error
import urllib.request

import boto3

API_URL = os.environ["API_URL"].rstrip("/")
EVIDENCE_BUCKET = os.environ["EVIDENCE_BUCKET"]
REQUEST_TIMEOUT = 3

_s3 = boto3.client("s3")


def probe(run_id, seq):
    body = json.dumps({"run_id": run_id, "seq": seq, "client_ts": time.time()}).encode()
    req = urllib.request.Request(
        f"{API_URL}/orders",
        data=body,
        method="POST",
        headers={"content-type": "application/json", "user-agent": "dr-proof-prober/1.0"},
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
    # Only an explicit commit counts. A timeout may or may not have written -
    # the client was not told it succeeded, so it is not part of the RPO promise.
    sample["acked"] = sample["status"] == 201 and payload.get("committed") is True
    return sample


def handler(event, context):
    run_id = event["run_id"]
    max_seconds = float(event.get("max_seconds", 840))
    no_fault_timeout = float(event.get("no_fault_timeout_seconds", 420))
    recovery_threshold = int(event.get("recovery_success_threshold", 30))
    interval = float(event.get("interval_seconds", 1.0))

    samples, seq = [], 0
    seen_failure, streak = False, 0
    t0 = time.time()
    stop_reason = None

    while stop_reason is None:
        elapsed = time.time() - t0
        if context.get_remaining_time_in_millis() < 20_000:
            stop_reason = "lambda_deadline"
            break
        if elapsed > max_seconds:
            stop_reason = "max_duration"
            break
        if not seen_failure and elapsed > no_fault_timeout:
            stop_reason = "no_fault_observed"
            break

        s = probe(run_id, seq)
        samples.append(s)
        if s["acked"]:
            streak = streak + 1 if seen_failure else 0
        else:
            seen_failure, streak = True, 0
        if seen_failure and streak >= recovery_threshold:
            stop_reason = "recovered"

        seq += 1
        time.sleep(max(0.0, t0 + seq * interval - time.time()))

    key = f"drills/{run_id}/samples.jsonl"
    _s3.put_object(
        Bucket=EVIDENCE_BUCKET,
        Key=key,
        Body="\n".join(json.dumps(s, separators=(",", ":")) for s in samples).encode(),
        ContentType="application/x-ndjson",
    )

    return {
        "samples_key": key,
        "sample_count": len(samples),
        "acked_count": sum(1 for s in samples if s["acked"]),
        "stop_reason": stop_reason,
        "started_at": t0,
        "ended_at": time.time(),
    }
