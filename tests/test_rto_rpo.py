import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "analyzer"))

import rto_rpo  # noqa: E402

P, S = "us-east-1", "us-west-2"
T0 = 1_760_000_000.0


def make_samples(pattern):
    """pattern: list of 'p' (acked by primary), 's' (acked by secondary), 'x' (failed); 1 s apart."""
    out = []
    for seq, kind in enumerate(pattern):
        t = T0 + seq
        out.append({
            "seq": seq,
            "t_send": t,
            "t_recv": t + 0.2,
            "status": 201 if kind != "x" else 500,
            "acked": kind != "x",
            "region": {"p": P, "s": S}.get(kind),
        })
    return out


def acked_seqs(samples, region=None):
    return {s["seq"] for s in samples if s["acked"] and (region is None or s["region"] == region)}


def run(samples, surviving, **kw):
    return rto_rpo.compute(
        samples,
        primary_region=P,
        secondary_region=S,
        surviving=surviving,
        rto_target=kw.pop("rto_target", 300),
        rpo_target=kw.pop("rpo_target", 5),
        **kw,
    )


def test_clean_failover_passes_with_zero_rpo():
    samples = make_samples("p" * 60 + "x" * 120 + "s" * 30)
    everything = acked_seqs(samples)
    r = run(samples, {"aurora": everything, "dynamodb": everything})

    assert r["verdict"] == rto_rpo.PASS
    # outage starts at seq 60 send, recovers at seq 180 recv (+0.2)
    assert r["rto_seconds"] == pytest.approx(120.2)
    assert r["rpo_seconds"] == 0
    assert r["rpo_by_store"]["aurora"]["acknowledged_by_old_primary"] == 60
    assert r["probe"]["recovered_region"] == S


def test_lost_tail_writes_measure_rpo_window():
    samples = make_samples("p" * 60 + "x" * 100 + "s" * 30)
    # the last 3 writes the primary acknowledged never reached the DR region
    survived = acked_seqs(samples) - {57, 58, 59}
    r = run(samples, {"aurora": survived, "dynamodb": acked_seqs(samples)})

    aurora = r["rpo_by_store"]["aurora"]
    assert aurora["lost_writes"] == 3
    assert aurora["lost_seqs"] == [57, 58, 59]
    # newest lost ack (seq 59) minus newest surviving ack before it (seq 56)
    assert aurora["rpo_seconds"] == pytest.approx(3.0)
    assert r["rpo_seconds"] == pytest.approx(3.0)
    assert r["verdict"] == rto_rpo.PASS  # 3 s is inside the 5 s target


def test_rpo_over_target_fails():
    samples = make_samples("p" * 60 + "x" * 100 + "s" * 30)
    survived = acked_seqs(samples) - set(range(50, 60))
    r = run(samples, {"aurora": survived, "dynamodb": acked_seqs(samples)})

    assert r["verdict"] == rto_rpo.FAIL
    assert any("aurora: RPO" in reason for reason in r["reasons"])


def test_rto_over_target_fails():
    samples = make_samples("p" * 10 + "x" * 400 + "s" * 30)
    everything = acked_seqs(samples)
    r = run(samples, {"aurora": everything, "dynamodb": everything})

    assert r["verdict"] == rto_rpo.FAIL
    assert r["rto_seconds"] > 300


def test_never_recovered_fails_without_rto():
    samples = make_samples("p" * 10 + "x" * 50)
    r = run(samples, {"aurora": acked_seqs(samples), "dynamodb": acked_seqs(samples)})

    assert r["verdict"] == rto_rpo.FAIL
    assert r["rto_seconds"] is None
    assert "did not recover" in r["reasons"][0]


def test_no_outage_is_inconclusive_not_pass():
    samples = make_samples("p" * 100)
    r = run(samples, {"aurora": acked_seqs(samples), "dynamodb": acked_seqs(samples)})

    assert r["verdict"] == rto_rpo.INCONCLUSIVE
    assert r["rto_seconds"] is None


def test_unreadable_store_is_unverified_and_fails():
    samples = make_samples("p" * 20 + "x" * 30 + "s" * 30)
    r = run(samples, {"aurora": None, "dynamodb": acked_seqs(samples)})

    assert r["verdict"] == rto_rpo.FAIL
    assert r["rpo_by_store"]["aurora"]["verified"] is False
    assert r["rpo_seconds"] is None  # no partial RPO claims


def test_recovery_on_primary_is_flagged():
    # fault cleared before failover - service came back, but not via DR
    samples = make_samples("p" * 20 + "x" * 30 + "p" * 30)
    everything = acked_seqs(samples)
    r = run(samples, {"aurora": everything, "dynamodb": everything})

    assert r["verdict"] == rto_rpo.FAIL
    assert any("failover did not happen" in reason for reason in r["reasons"])


def test_flapping_counts_from_first_failure_to_final_recovery():
    samples = make_samples("p" * 10 + "x" * 5 + "p" * 2 + "x" * 20 + "s" * 30)
    everything = acked_seqs(samples)
    r = run(samples, {"aurora": everything, "dynamodb": everything})

    assert r["probe"]["first_failure_seq"] == 10
    assert r["probe"]["recovery_seq"] == 37
    assert r["rto_seconds"] == pytest.approx(27.2)
    # writes acked by the primary during the flap are part of the RPO promise
    assert r["rpo_by_store"]["aurora"]["acknowledged_by_old_primary"] == 12


def test_phase_breakdown_uses_runbook_timestamps():
    samples = make_samples("p" * 60 + "x" * 120 + "s" * 30)
    everything = acked_seqs(samples)
    outage = T0 + 60
    timeline = {
        "detected_at": rto_rpo.iso(outage + 15),
        "failover_started_at": rto_rpo.iso(outage + 15.5),
        "failover_issued_at": rto_rpo.iso(outage + 16),
        "promoted_at": rto_rpo.iso(outage + 76),
        "verified_at": rto_rpo.iso(outage + 81),
    }
    r = run(samples, {"aurora": everything, "dynamodb": everything}, timeline=timeline, fault_injected_at=outage - 40)

    ph = r["phases"]
    assert ph["fault_to_first_error"] == pytest.approx(40)
    assert ph["detection"] == pytest.approx(15)
    assert ph["runbook_start"] == pytest.approx(0.5)
    assert ph["db_promotion"] == pytest.approx(60)
    assert ph["dr_verification"] == pytest.approx(5)
    assert ph["dns_and_client"] == pytest.approx(120.2 - 81)


def test_client_recovered_but_runbook_stuck_fails():
    # Real case from the first drill: Aurora promoted and DNS moved, but the
    # runbook never recognised the promotion and stayed in FAILING_OVER.
    samples = make_samples("p" * 60 + "x" * 120 + "s" * 30)
    everything = acked_seqs(samples)
    r = run(samples, {"aurora": everything, "dynamodb": everything}, runbook_state="FAILING_OVER")

    assert r["verdict"] == rto_rpo.FAIL
    assert r["rto_seconds"] == pytest.approx(120.2)  # still measured and reported
    assert any("runbook did not complete" in reason for reason in r["reasons"])


def test_parse_ts_handles_step_functions_and_sentinels():
    assert rto_rpo.parse_ts("2026-10-26T12:00:00.123Z") == pytest.approx(1793016000.123)
    assert rto_rpo.parse_ts("n/a") is None
    assert rto_rpo.parse_ts(None) is None
    assert rto_rpo.parse_ts(12.5) == 12.5
