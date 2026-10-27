"""Grading for active-active drills. Pure functions, no AWS calls, unit-tested.

Inputs are exactly what the drill observed:
  clients   {client_name: [sample, ...]}   one sample per write attempt
  fault     {"start": epoch, "end": epoch | None}  when FIS actually impaired the region
  persisted {region: {client_name: set(seq)} | None}  rows read back from each
            region's DSQL endpoint after the drill; None = could not be read

What "good" means for active-active is different from active-passive:
  * there is no failover runbook - the only recovery mechanism is Route 53
    moving each client off the impaired region, so the user-visible outage is
    the longest run of failed writes any client saw;
  * a client homed on the healthy region should notice nothing;
  * every acknowledged write must be readable from EVERY region (RPO = 0 is a
    property of synchronous replication, not a lucky outcome), and
  * once the fault ends, traffic returns home on its own.
"""

from __future__ import annotations

import collections
import math


def percentile(values, q):
    """Nearest-rank percentile; None for no data."""
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    rank = max(1, math.ceil(q / 100 * len(values)))
    return values[rank - 1]


def _round(v, nd=1):
    return None if v is None else round(v, nd)


def home_region(samples, fault_start):
    """Region that served most acknowledged writes before the fault began."""
    counts = collections.Counter(
        s["region"] for s in samples if s["acked"] and s.get("region") and (fault_start is None or s["t_send"] < fault_start)
    )
    return counts.most_common(1)[0][0] if counts else None


def outages(samples):
    """Windows of consecutive failed writes: first failed send -> next acknowledged send."""
    windows, start = [], None
    for s in samples:
        if not s["acked"] and start is None:
            start = s["t_send"]
        elif s["acked"] and start is not None:
            windows.append({"start": start, "end": s["t_send"], "recovered": True})
            start = None
    if start is not None:
        last = samples[-1]
        windows.append({"start": start, "end": last.get("t_recv", last["t_send"]), "recovered": False})
    for w in windows:
        w["seconds"] = round(w["end"] - w["start"], 1)
    return windows


def client_report(samples, fault_start, fault_end):
    home = home_region(samples, fault_start)
    acked = [s for s in samples if s["acked"]]
    windows = outages(samples)
    latency = {s["seq"]: (s["t_recv"] - s["t_send"]) * 1000 for s in acked}
    baseline = [s for s in acked if fault_start is None or s["t_send"] < fault_start]

    rerouted_at = returned_at = None
    if home and fault_start is not None:
        rerouted = next((s for s in acked if s["t_send"] >= fault_start and s["region"] != home), None)
        if rerouted:
            rerouted_at = rerouted["t_send"]
            if fault_end is not None:
                back = next((s for s in acked if s["t_send"] >= max(fault_end, rerouted_at) and s["region"] == home), None)
                returned_at = back["t_send"] if back else None

    in_fault = [
        s for s in samples
        if fault_start is not None and s["t_send"] >= fault_start and (fault_end is None or s["t_send"] < fault_end)
    ]
    served = collections.Counter(s["region"] for s in acked)

    return {
        "home_region": home,
        "samples": len(samples),
        "acked": len(acked),
        "failed": len(samples) - len(acked),
        "availability_pct": _round(100 * len(acked) / len(samples), 2) if samples else None,
        "failed_during_fault": sum(1 for s in in_fault if not s["acked"]),
        "served_by": dict(served),
        "outages": windows,
        "max_outage_seconds": max((w["seconds"] for w in windows), default=0.0),
        "rerouted_after_seconds": _round(rerouted_at - fault_start) if rerouted_at else None,
        "returned_home_after_seconds": _round(returned_at - fault_end) if returned_at else None,
        "latency_ms": {
            "baseline_p50": _round(percentile([latency[s["seq"]] for s in baseline], 50)),
            "baseline_p99": _round(percentile([latency[s["seq"]] for s in baseline], 99)),
            "all_p50": _round(percentile(latency.values(), 50)),
            "all_p99": _round(percentile(latency.values(), 99)),
            "commit_p50": _round(percentile([s.get("commit_ms") for s in baseline], 50)),
        },
    }


def durability(clients, persisted):
    """Acknowledged writes missing from each region's copy of the data."""
    by_region = {}
    for region, rows in persisted.items():
        if rows is None:
            by_region[region] = {"verified": False, "lost_acked_writes": None, "rpo_seconds": None}
            continue
        lost, ambiguous = [], 0
        for name, samples in clients.items():
            have = rows.get(name, set())
            lost.extend(s for s in samples if s["acked"] and s["seq"] not in have)
            ambiguous += sum(1 for s in samples if not s["acked"] and s["seq"] in have)
        span = (max(s["t_send"] for s in lost) - min(s["t_send"] for s in lost) + 1) if lost else 0.0
        by_region[region] = {
            "verified": True,
            "lost_acked_writes": len(lost),
            "rpo_seconds": round(span, 1),
            # Writes the client gave up on that did commit: harmless (idempotent
            # keys) but worth reporting - it is why clients must retry safely.
            "unacked_but_persisted": ambiguous,
        }
    return by_region


def compute(clients, fault, persisted, impaired_region, targets):
    fault_start, fault_end = fault.get("start"), fault.get("end")
    reports = {name: client_report(samples, fault_start, fault_end) for name, samples in clients.items()}
    stores = durability(clients, persisted)
    max_outage_target = targets["max_outage_seconds"]

    reasons = []
    for region, d in stores.items():
        if not d["verified"]:
            reasons.append(f"{region}: surviving writes could not be read, so RPO is unverified")
        elif d["lost_acked_writes"]:
            reasons.append(f"{region}: {d['lost_acked_writes']} acknowledged writes missing (RPO {d['rpo_seconds']}s, target 0)")

    for name, r in reports.items():
        if r["max_outage_seconds"] > max_outage_target:
            reasons.append(f"client {name}: longest outage {r['max_outage_seconds']}s exceeds target {max_outage_target}s")

    impacted = {n: r for n, r in reports.items() if r["home_region"] == impaired_region}
    fault_bit = fault_start is not None and any(r["failed_during_fault"] or r["rerouted_after_seconds"] is not None for r in impacted.values())
    for name, r in impacted.items():
        if fault_bit and r["rerouted_after_seconds"] is None:
            reasons.append(f"client {name}: traffic never moved off {impaired_region}")

    if reasons:
        verdict = "FAIL"
    elif not fault_bit:
        verdict = "INCONCLUSIVE"
        reasons.append(f"no client homed on {impaired_region} saw the fault - nothing was tested")
    else:
        verdict = "PASS"

    worst_impacted = max((r["max_outage_seconds"] for r in impacted.values()), default=None)
    lost_total = sum(d["lost_acked_writes"] or 0 for d in stores.values())
    return {
        "verdict": verdict,
        "reasons": reasons,
        "impaired_region": impaired_region,
        "fault": {"start": fault_start, "end": fault_end, "seconds": _round(fault_end - fault_start) if fault_start and fault_end else None},
        "headline": {
            "impacted_client_max_outage_seconds": worst_impacted,
            "rerouted_after_seconds": max((r["rerouted_after_seconds"] for r in impacted.values() if r["rerouted_after_seconds"] is not None), default=None),
            "returned_home_after_seconds": max((r["returned_home_after_seconds"] for r in impacted.values() if r["returned_home_after_seconds"] is not None), default=None),
            "unaffected_client_failed_writes": sum(r["failed"] for n, r in reports.items() if n not in impacted),
            "acked_writes": sum(r["acked"] for r in reports.values()),
            "lost_acked_writes": lost_total if all(d["verified"] for d in stores.values()) else None,
        },
        "clients": reports,
        "durability": stores,
        "targets": {"max_outage_seconds": max_outage_target, "rpo_seconds": 0},
    }
