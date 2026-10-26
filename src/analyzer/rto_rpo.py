"""Pure RTO/RPO computation - no AWS calls, fully unit-tested.

Definitions (deliberately client-centric):

* Outage start  - send time of the first probe that was NOT acknowledged.
* Recovered at  - receive time of the first acknowledged probe after the last
                  failed one (i.e. the start of the streak that ended the drill).
* RTO           - recovered_at - outage_start: how long real clients could not
                  write. Resolution is the probe interval (1 s).
* RPO           - for every write the OLD primary acknowledged that is missing
                  from a store after failover, the gap back to the newest
                  surviving acknowledged write before it; RPO is the largest
                  such gap (0 when nothing acknowledged was lost).

Missing evidence is never treated as success: if a store could not be read
after failover, RPO for that store is "unverified" and the drill FAILs.
"""

from __future__ import annotations

import bisect
from datetime import datetime, timezone
from typing import Iterable

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"


def parse_ts(value) -> float | None:
    """ISO-8601 (Step Functions / DynamoDB strings) or epoch -> epoch seconds."""
    if value is None or value in ("", "n/a"):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).replace("Z", "+00:00")
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _delta(later: float | None, earlier: float | None) -> float | None:
    if later is None or earlier is None:
        return None
    return round(later - earlier, 3)


def _store_rpo(old_acked: list[dict], surviving: Iterable[int] | None) -> dict:
    if surviving is None:
        return {"verified": False, "acknowledged_by_old_primary": len(old_acked), "lost_writes": None, "rpo_seconds": None}

    surviving = set(surviving)
    kept = sorted(s["t_recv"] for s in old_acked if s["seq"] in surviving)
    lost = [s for s in old_acked if s["seq"] not in surviving]

    worst = 0.0
    for s in lost:
        i = bisect.bisect_right(kept, s["t_recv"])
        anchor = kept[i - 1] if i else old_acked[0]["t_send"]
        worst = max(worst, s["t_recv"] - anchor)

    return {
        "verified": True,
        "acknowledged_by_old_primary": len(old_acked),
        "lost_writes": len(lost),
        "lost_seqs": [s["seq"] for s in lost][:50],
        "rpo_seconds": round(worst, 3),
    }


def compute(
    samples: list[dict],
    *,
    primary_region: str,
    secondary_region: str,
    surviving: dict[str, Iterable[int] | None],
    timeline: dict | None = None,
    fault_injected_at: float | None = None,
    rto_target: float,
    rpo_target: float,
) -> dict:
    samples = sorted(samples, key=lambda s: s["seq"])
    timeline = timeline or {}
    reasons: list[str] = []

    failures = [i for i, s in enumerate(samples) if not s["acked"]]
    probe_stats = {
        "total": len(samples),
        "acked": len(samples) - len(failures),
        "failed": len(failures),
        "resolution_seconds": round(samples[1]["t_send"] - samples[0]["t_send"], 3) if len(samples) > 1 else None,
    }

    if not failures:
        return {
            "verdict": INCONCLUSIVE,
            "reasons": ["no outage observed by the client - the fault did not take effect"],
            "rto_seconds": None,
            "rpo_seconds": None,
            "rpo_by_store": {},
            "phases": {},
            "probe": probe_stats,
            "timestamps": {"fault_injected_at": iso(fault_injected_at)},
        }

    first_fail, last_fail = failures[0], failures[-1]
    outage_start = samples[first_fail]["t_send"]
    recovery = samples[last_fail + 1] if last_fail + 1 < len(samples) else None
    recovered_at = recovery["t_recv"] if recovery else None
    rto = _delta(recovered_at, outage_start)

    probe_stats.update({
        "first_failure_seq": samples[first_fail]["seq"],
        "recovery_seq": recovery["seq"] if recovery else None,
        "recovered_region": recovery.get("region") if recovery else None,
    })

    # Writes the old primary told clients were committed.
    old_acked = [
        s for s in samples
        if s["acked"] and (s.get("region") == primary_region or (s.get("region") is None and s["seq"] < samples[first_fail]["seq"]))
    ]
    rpo_by_store = {store: _store_rpo(old_acked, seqs) for store, seqs in surviving.items()}

    detected_at = parse_ts(timeline.get("detected_at"))
    started_at = parse_ts(timeline.get("failover_started_at"))
    issued_at = parse_ts(timeline.get("failover_issued_at"))
    promoted_at = parse_ts(timeline.get("promoted_at"))
    verified_at = parse_ts(timeline.get("verified_at"))

    phases = {
        "fault_to_first_error": _delta(outage_start, fault_injected_at),
        "detection": _delta(detected_at, outage_start),
        "runbook_start": _delta(started_at, detected_at),
        "db_promotion": _delta(promoted_at, issued_at),
        "dr_verification": _delta(verified_at, promoted_at),
        # Route 53 health-check flip + DNS TTL + client resolver. Can be negative
        # if Route 53 saw the DR region healthy before the runbook's own check.
        "dns_and_client": _delta(recovered_at, verified_at),
    }

    if recovery is None:
        reasons.append("service did not recover within the probe window")
    elif rto > rto_target:
        reasons.append(f"RTO {rto:.1f}s exceeds target {rto_target:.0f}s")

    if recovery is not None and recovery.get("region") == primary_region:
        reasons.append("recovered on the primary region - failover did not happen (fault ended first?)")

    rpos = []
    for store, r in rpo_by_store.items():
        if not r["verified"]:
            reasons.append(f"{store}: surviving data could not be read after failover - RPO unverified")
        else:
            rpos.append(r["rpo_seconds"])
            if r["rpo_seconds"] > rpo_target:
                reasons.append(f"{store}: RPO {r['rpo_seconds']:.1f}s exceeds target {rpo_target:.0f}s ({r['lost_writes']} acknowledged writes lost)")

    return {
        "verdict": FAIL if reasons else PASS,
        "reasons": reasons,
        "rto_seconds": rto,
        "rpo_seconds": max(rpos) if rpos and len(rpos) == len(rpo_by_store) else None,
        "rpo_by_store": rpo_by_store,
        "phases": phases,
        "probe": probe_stats,
        "timestamps": {
            "fault_injected_at": iso(fault_injected_at),
            "outage_start": iso(outage_start),
            "detected_at": iso(detected_at),
            "failover_started_at": iso(started_at),
            "failover_issued_at": iso(issued_at),
            "promoted_at": iso(promoted_at),
            "verified_at": iso(verified_at),
            "recovered_at": iso(recovered_at),
        },
    }
