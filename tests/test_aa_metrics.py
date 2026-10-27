import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "active-active" / "src" / "analyzer"))

import aa_metrics  # noqa: E402

E, W = "us-east-1", "us-west-2"
T0 = 1_760_000_000.0
TARGETS = {"max_outage_seconds": 120}


def make_samples(pattern, t0=T0):
    """pattern: 'e' acked by east, 'w' acked by west, 'x' failed; one per second."""
    out = []
    for seq, kind in enumerate(pattern):
        t = t0 + seq
        out.append({
            "seq": seq,
            "t_send": t,
            "t_recv": t + (0.05 if kind == "e" else 0.08),
            "status": 201 if kind != "x" else 500,
            "acked": kind != "x",
            "region": {"e": E, "w": W}.get(kind),
            "commit_ms": 12.0 if kind != "x" else None,
        })
    return out


def acked(samples):
    return {s["seq"] for s in samples if s["acked"]}


def everything_persisted(clients):
    rows = {name: acked(s) for name, s in clients.items()}
    return {E: rows, W: rows}


# east client: 10 s baseline on east, fault at t=10 for 40 s, 15 failed writes,
# then served by west until the fault ends, then back home.
EAST = "e" * 10 + "x" * 15 + "w" * 25 + "e" * 10
WEST = "w" * 60
FAULT = {"start": T0 + 10, "end": T0 + 50}


def run(clients, persisted=None, fault=FAULT):
    return aa_metrics.compute(clients, fault, persisted or everything_persisted(clients), E, TARGETS)


def test_clean_regional_shift_passes():
    clients = {"east": make_samples(EAST), "west": make_samples(WEST)}
    r = run(clients)
    assert r["verdict"] == "PASS", r["reasons"]
    east = r["clients"]["east"]
    assert east["home_region"] == E
    assert east["max_outage_seconds"] == 15.0
    assert east["rerouted_after_seconds"] == 15.0
    assert east["returned_home_after_seconds"] == 0.0
    assert r["headline"]["unaffected_client_failed_writes"] == 0
    assert r["headline"]["lost_acked_writes"] == 0


def test_lost_write_in_either_region_fails():
    clients = {"east": make_samples(EAST), "west": make_samples(WEST)}
    persisted = everything_persisted(clients)
    persisted = {E: persisted[E], W: {"east": acked(clients["east"]) - {3}, "west": acked(clients["west"])}}
    r = run(clients, persisted)
    assert r["verdict"] == "FAIL"
    assert r["durability"][W]["lost_acked_writes"] == 1
    assert r["durability"][E]["lost_acked_writes"] == 0
    assert any("us-west-2" in reason for reason in r["reasons"])


def test_unreadable_region_is_unverified_and_fails():
    clients = {"east": make_samples(EAST), "west": make_samples(WEST)}
    persisted = everything_persisted(clients)
    persisted[E] = None
    r = run(clients, persisted)
    assert r["verdict"] == "FAIL"
    assert r["headline"]["lost_acked_writes"] is None
    assert any("unverified" in reason for reason in r["reasons"])


def test_outage_longer_than_target_fails():
    clients = {"east": make_samples("e" * 10 + "x" * 130 + "w" * 10), "west": make_samples(WEST)}
    r = run(clients, fault={"start": T0 + 10, "end": T0 + 200})
    assert r["verdict"] == "FAIL"
    assert r["clients"]["east"]["max_outage_seconds"] == 130.0


def test_fault_that_never_bit_is_inconclusive():
    clients = {"east": make_samples("e" * 60), "west": make_samples(WEST)}
    r = run(clients)
    assert r["verdict"] == "INCONCLUSIVE"


def test_errors_without_traffic_shift_fail():
    # Health checks never moved the client: it just waited for the fault to end.
    clients = {"east": make_samples("e" * 10 + "x" * 40 + "e" * 10), "west": make_samples(WEST)}
    r = run(clients, fault={"start": T0 + 10, "end": T0 + 50})
    assert r["verdict"] == "FAIL"
    assert any("never moved" in reason for reason in r["reasons"])


def test_unacked_write_that_committed_is_reported_not_counted_as_loss():
    clients = {"east": make_samples(EAST), "west": make_samples(WEST)}
    persisted = everything_persisted(clients)
    persisted[W] = {**persisted[W], "east": persisted[W]["east"] | {12}}
    r = run(clients, persisted)
    assert r["verdict"] == "PASS"
    assert r["durability"][W]["unacked_but_persisted"] == 1


def test_unrecovered_outage_runs_to_last_sample():
    windows = aa_metrics.outages(make_samples("ee" + "x" * 5))
    assert windows == [{"start": T0 + 2, "end": T0 + 6 + 0.08, "recovered": False, "seconds": 4.1}]


def test_percentile_nearest_rank():
    assert aa_metrics.percentile([5, 1, 3, 2, 4], 50) == 3
    assert aa_metrics.percentile(list(range(1, 101)), 99) == 99
    assert aa_metrics.percentile([], 50) is None
