# Automated Disaster Recovery with Proven RTO/RPO

Multi-region disaster recovery on AWS, built twice:
- **active-passive:** Aurora Global Database, DynamoDB global tables, Route 53
  health-check failover and an automated failover runbook;
- **active-active:** Aurora DSQL multi-Region with Route 53 latency routing.

Both get the part most DR setups skip: **a scheduled chaos drill that
breaks the primary region with AWS Fault Injection Service, lets the
automation recover on its own, and publishes the measured recovery time and
data loss.**

Most teams claim DR. Very few can show evidence that it works. This repo
is built to produce that evidence on a schedule and commit it next to the
code, including the runs that fail.

It contains two architectures. Each was drilled against real AWS with an FIS
regional impairment and graded automatically from client-observed data:

| | Phase 1: active-passive ([terraform/](terraform/)) | Phase 2: active-active ([active-active/](active-active/)) |
|---|---|---|
| Who serves traffic | us-east-1 only; us-west-2 is a pilot light | **Both regions, all the time** |
| Database | Aurora Global Database (one writer, async) + DynamoDB global table | **Aurora DSQL multi-Region** (both writable, synchronous, witness in us-east-2) |
| Recovery mechanism | Watchdog → Step Functions runbook → promote Aurora → DNS failover | **DNS only**: Route 53 latency routing stops sending clients to the sick region |
| Longest outage a client saw | **129 s** (best run) | **54 s** |
| Confirmed writes lost | Aurora 0; **DynamoDB 33** when replication broke first | **0 of 1,265**, read back from both regions |
| Clients on the healthy region | n/a (all traffic was on the primary) | **0 failed writes** |
| Return to normal | Planned failback runbook, 88.6 s | **Automatic**, 28 s after the fault ended |
| Drill verdict | 0/2 PASS (both defects fixed, see below) | **1/1 PASS** |

## Measured results: Phase 1 (active-passive)

<!-- RESULTS:START -->
| Latest drill | Verdict | Measured RTO | Measured RPO | Target RTO / RPO |
|---|---|---|---|---|
| `drill-20261026T204238Z` | **FAIL** | 129.1 s | 33.0 s | 300 s / 5 s |

Across **2** drills: 0/2 passed, RTO p50 168.1 s / worst 207.1 s, worst RPO 33.0 s. Full history: [docs/RESULTS.md](docs/RESULTS.md).
<!-- RESULTS:END -->

Every number above comes from `evidence/drills/<run>/result.json`. The raw
per-second probe samples and the full Step Functions execution history sit
next to it, so each figure can be recomputed.

## What the first real drills found

The first session against real AWS (2026-10-26) ran three drills and one
failback. Two bugs surfaced that no local test, `terraform validate` or
checkov scan could catch, plus one genuine data-loss finding. All of it is
in the evidence folder, including the failures.

| Run | What happened | Result |
|---|---|---|
| `drill-20261026T201353Z` | Blocked before any fault was injected: the first `StartExperiment` in an account creates the FIS service-linked role, and the drill-control role was denied `iam:CreateServiceLinkedRole` | Not graded. Fixed with a permission scoped to that one role |
| `drill-20261026T201739Z` | Failover **worked**: Aurora promoted us-west-2, Route 53 moved traffic, 0 of 128 acknowledged writes lost. But the runbook never recognised the promotion and polled for 14 minutes | **FAIL**: RTO 207 s, RPO 0 s, runbook incomplete |
| failback after the fix | Planned `SwitchoverGlobalCluster` back to us-east-1, verified from outside | **88.6 s**, zero data loss |
| `drill-20261026T204238Z` | Runbook succeeded in **52 s**. RTO **129 s**, broken down as detect 12 s → promote 20.5 s → verify 31 s → DNS + client 64.5 s. Aurora lost nothing; **DynamoDB lost 33 acknowledged writes** | **FAIL**: DynamoDB RPO 33 s against a 5 s target |

### Bug: the runbook looked for a field that doesn't exist

Step Functions' AWS SDK integrations return field names from the Java SDK,
so the global-cluster member field is `DbClusterArn`. The CLI and boto3
spell the same field `DBClusterArn`. The runbook's writer-detection
expression used the boto3 spelling, so it never matched, even while Aurora
reported us-west-2 as the writer. Local validation passed because the test
data was written in boto3 casing; only a real execution exposed it. The fix
was then verified against the exact SDK response captured from the stuck
run.

![Stuck runbook: running for 8 minutes, 151 state transitions](docs/screenshots/bug-01-runbook-stuck-8min.png)
*The stuck execution: Aurora had already failed over, but the runbook kept polling `WaitForPromotion` ⇄ `CheckPromotion`.*

This run also changed the grading rules. The analyzer at the time graded it
**PASS**, because clients recovered within target. But a runbook that never
finishes means no notification, no verified state and a disarmed watchdog,
so the analyzer now fails any drill whose runbook doesn't complete. The run
was re-graded with the original inputs; the earlier PASS is kept as a prior
version in the versioned evidence bucket.

### Finding: DynamoDB RPO when the replication link fails first

In drill 3 the FIS experiment cut DynamoDB replication about 40 seconds
before the Lambda fault reached every execution environment. For that
window us-east-1 kept acknowledging writes that could no longer reach
us-west-2. The 33 lost writes (sequence 79–111) end exactly one write before
the first client error (sequence 112). Aurora lost nothing, because its
storage-level replication was never cut.

That's what real regional failures often look like: the network between
regions degrades before the application fails. **Asynchronous multi-region
replication can't guarantee a 5 s RPO in that scenario.** The writes
reappear once the region returns, but they are unavailable at failover time,
which is what RPO measures. Options:
- accept and document the RPO;
- make the application acknowledge a write only while replication is
  healthy (trading availability for durability);
- use DynamoDB multi-Region strong consistency, which gives RPO 0 but needs
  a third region or a witness. This is planned for the active-active phase.

Drill 2 never showed this: per AWS docs the replication pause can take up to
5 minutes to take full effect, and that time it hadn't. The same experiment
produced different exposure, which is exactly why drills need to run more
than once.

### Smaller observations
- **FIS ramps up gradually.** Detection took 80 s in drill 2 and 12 s in
  drill 3. The FIS Lambda extension picks up faults per execution
  environment on its own polling cycle, so during ramp-up some health probes
  still succeed and keep resetting the watchdog's "3 in a row" failure
  counter.
- **AWS retires engine versions.** Aurora PostgreSQL 16.6, the first version
  chosen, no longer existed in either region by deploy time. A pre-apply
  check caught it before a failed 20-minute apply.

## A Phase 1 drill in screenshots

All from the same session; run IDs match the committed evidence.

| | |
|---|---|
| ![Global DB before](docs/screenshots/02-aurora-global-before.png) **Before:** one writer in us-east-1, a warm secondary in us-west-2 | ![Health before](docs/screenshots/03-route53-health-before.png) **Before:** the DR region reports unhealthy by design until it holds the writer |
| ![FIS running](docs/screenshots/05-fis-experiment-running.png) **Break it:** AWS FIS impairs the primary region | ![Both unhealthy](docs/screenshots/06-route53-both-unhealthy.png) **Outage window:** neither region can commit writes |
| ![Watchdog fired](docs/screenshots/06b-watchdog-started-failover.png) **Detect:** the watchdog in us-west-2 starts the runbook (`auto-…`, no human) | ![Failover graph](docs/screenshots/07-failover-graph-all-green.png) **Recover:** the failover runbook, all green |
| ![Succeeded](docs/screenshots/08-failover-succeeded-52s.png) **52 seconds** from detection to verified DR | ![Traffic moved](docs/screenshots/09-route53-traffic-moved-to-dr.png) **Traffic moved:** the DR region now healthy |
| ![Global DB after](docs/screenshots/11-aurora-global-after-failover.png) **After:** us-west-2 is the writer; the old primary resyncs | ![Failback](docs/screenshots/15-failback-succeeded-88s.png) **Return trip:** planned failback in 88.6 s |
| ![Drill graph](docs/screenshots/13-drill-graph.png) **The drill:** probe and chaos branches in parallel, then grading | ![Dashboard](docs/screenshots/10-dashboard-full-session.png) **The whole session** on one dashboard: apply, failover, failback, failover |

## Phase 2: active-active with Aurora DSQL

Phase 1 proved that an automated failover *works* and measured what it
costs: two minutes of errors and, for the asynchronous store, real data
loss. Phase 2 asks whether both can go away. Both regions take writes all the
time, and recovery is nothing more than DNS.

```mermaid
flowchart LR
    ce["East client<br/>(Lambda in us-east-2)"] --> r53{"Route 53<br/>latency records<br/>aa.dr.example.com"}
    cw["West client<br/>(Lambda in us-west-2)"] --> r53

    subgraph E["us-east-1 - active"]
        apiE["HTTP API + Lambda<br/>(FIS extension layer)"]
        dsqlE[("Aurora DSQL<br/>regional endpoint")]
        fis["AWS FIS<br/>fail every east API call"]
        apiE -- "IAM token, role app" --> dsqlE
        fis -. "invocation errors" .-> apiE
    end

    subgraph W["us-west-2 - active"]
        apiW["HTTP API + Lambda"]
        dsqlW[("Aurora DSQL<br/>regional endpoint")]
        an["Analyzer<br/>reads back from BOTH regions"]
        apiW -- "IAM token, role app" --> dsqlW
    end

    wit[("us-east-2<br/>DSQL witness")]

    r53 -- "nearest healthy" --> apiE
    r53 -- "nearest healthy" --> apiW
    dsqlE <== "synchronous commit (quorum)" ==> dsqlW
    dsqlE -.- wit
    dsqlW -.- wit
```

**The drill.** Two synthetic clients write once per second through the public
hostname for 11 minutes. Route 53 sends the client in us-east-2 to us-east-1
and the client in us-west-2 to us-west-2, as it would real users. After a
60 s baseline, FIS fails every east API invocation for 5 minutes. Nothing
performs a failover. The drill only watches what clients experience, then
reads every write back from **each** region's DSQL endpoint.

**Grading.** PASS needs all of these:
- no client sees an outage longer than 120 s;
- every acknowledged write is present in both regions (RPO = 0, no tolerance);
- the impaired region's clients actually moved to the other region.

A region whose data can't be read back makes the run FAIL as unverified. A
fault that never bit makes it INCONCLUSIVE. The logic is in
[active-active/src/analyzer/aa_metrics.py](active-active/src/analyzer/aa_metrics.py)
and has its own unit tests.

### Result: `aa-drill-20261027T180932Z`, PASS

| Measured | Value |
|---|---|
| East client's longest outage | **54.0 s** (target 120 s) |
| Time from fault to east client being served by us-west-2 | 88.5 s after FIS started. The FIS extension took 34.5 s to fail calls consistently (after one 1 s blip at 14.5 s); the outage itself ran 18:12:58-18:13:52 UTC |
| Back on us-east-1 after the fault ended | **27.9 s**, no human or runbook |
| West client | 660/660 writes acknowledged, **0 failed** |
| Acknowledged writes lost | **0 of 1,265**, verified in us-east-1 and us-west-2 |
| Writes that committed but weren't acknowledged | 0 |
| Database commit time, median (from the API) | 88 ms (east), 81 ms (west): the cost of a synchronous cross-region quorum |
| Client-observed write latency, median | 150 ms (east client), 113 ms (west client) |

Evidence: [evidence/active-active/aa-drill-20261027T180932Z/](evidence/active-active/aa-drill-20261027T180932Z/)
(`result.json`, both clients' per-second samples, the FIS experiment record).

### Where the 54 seconds went

Route 53 checks each region's `/health` every 10 s from several locations and
needs 2 failures in a row. The alias answer then has to age out of the
client resolver's cache (60 s TTL). Health-check detection plus DNS caching
is the whole outage. There is no database step, because there's nothing to
promote. The next levers are client-side:
- retry the other region on a 5xx;
- shorter health-check thresholds;
- Route 53 Application Recovery Controller for a manual "drain east" switch.

### Phase 2 in screenshots

| | |
|---|---|
| ![Dashboard](docs/screenshots/aa-01-dashboard-regional-shift.png) **The drill on one screen.** us-east-1's health check drops at 18:13 and recovers at 18:18. The east client's writes move from us-east-1 (blue) to us-west-2 (orange) and back. The west client's line never moves. (Both checks read 0 until about 18:08 only because they had just been created.) | ![DSQL east](docs/screenshots/aa-02-dsql-east-peered.png) **One database, two writable regions.** The us-east-1 cluster is peered with us-west-2 |
| ![DSQL west](docs/screenshots/aa-03-dsql-west-peered-witness.png) **The witness.** us-east-2 holds only the transaction log, so a quorum survives losing either serving region | ![Health checks](docs/screenshots/aa-04-route53-health-checks.png) **Both regions healthy** in steady state (in Phase 1 the DR region was unhealthy by design) |
| ![Custom domain](docs/screenshots/aa-05-custom-domain-regional.png) **Same hostname, regional endpoints.** `aa.dr…` is served by a regional API in each region | ![FIS layer](docs/screenshots/aa-06-east-api-with-fis-layer.png) **The fault target.** The east API carries the FIS Lambda extension layer |
| ![IAM](docs/screenshots/aa-07-iam-role-no-password.png) **No database password anywhere.** The API role's only database permission is `dsql:DbConnect`, mapped to a SELECT/INSERT-only database role | ![FIS completed](docs/screenshots/aa-08-fis-experiment-completed.png) **The fault ran its full 5 minutes**, with a stop-condition alarm armed |
| ![Evidence](docs/screenshots/aa-09-evidence-bucket.png) **Evidence written by the drill**, then committed to this repo | |

### Security model

- **No passwords or secrets.** Every connection uses a 15-minute IAM token.
- **Three database roles, mapped with `AWS IAM GRANT`:**
  - `app`: SELECT and INSERT on one table, mapped to the two API roles;
  - `auditor`: SELECT only, mapped to the analyzer;
  - `admin`: used only by the one-off migrate function.
- **The mappings replicate.** The migrate function runs against both regional
  endpoints. The second run finds the roles and mappings already there and
  creates nothing.

### What Phase 2 does and doesn't prove

- **FIS has no fault action for DSQL.** The drill impairs the east compute
  tier, not the database. RPO = 0 here is verified by reading back every
  acknowledged write in both regions after the impairment. It doesn't show
  what happens if a DSQL region itself fails. AWS documents that case (the
  witness keeps a quorum), but this repo hasn't tested it.
- **Synchronous replication isn't free.** Every commit waits for a
  cross-region quorum, at roughly 80–90 ms here. Writes that suit this pattern
  are things like orders, balances and ledgers. For high-volume, low-value
  writes the asynchronous Phase 1 trade-off is often the better one.
- **Write conflicts aren't tested.** DSQL uses optimistic concurrency, so
  conflicting writes to the same row from two regions get a serialization
  error and must retry. The drill's writes never conflict (unique keys per
  client), so that path is unmeasured.
- **One run, one fault type.** The 54 s is one measurement, not a
  distribution. Treat it as a data point until more drills accumulate.
- **Both clients run inside AWS.** Real users' resolvers may hold DNS
  answers past the TTL.

### Running Phase 2

```bash
cd active-active/terraform
cp backend.hcl.example backend.hcl          # different state key from Phase 1
cp terraform.tfvars.example terraform.tfvars
bash ../scripts/build.sh                    # bundle the pure-Python Postgres driver
terraform init -backend-config=backend.hcl && terraform apply
bash ../scripts/run-drill.sh                # ~12 min; evidence lands in evidence/active-active/
bash ../scripts/teardown.sh
```

Cost per session (apply, one drill, teardown) is about $1–2:
- DSQL stays inside the free tier at drill volumes, and the witness is free;
- 2 HTTPS health checks, prorated;
- about $0.50 of FIS action time.

Left running idle, DSQL costs close to nothing, unlike Phase 1's Aurora ACU
floor.

## Phase 1 architecture: active-passive

```mermaid
flowchart LR
    client["Clients<br/>(prober: 1 write/s)"] --> r53{"Route 53<br/>failover record<br/>api-dr.example.com"}

    subgraph P["us-east-1 - primary"]
        apiP["HTTP API + Lambda<br/>(FIS extension layer)"]
        auroraP[("Aurora PG<br/>writer")]
        ddbP[("DynamoDB<br/>replica")]
        fis["AWS FIS<br/>region-impairment<br/>experiment"]
        apiP --> auroraP & ddbP
        fis -. "invocation errors" .-> apiP
        fis -. "pause replication" .-> ddbP
    end

    subgraph S["us-west-2 - DR (pilot light)"]
        apiS["HTTP API + Lambda"]
        auroraS[("Aurora PG<br/>secondary")]
        ddbS[("DynamoDB<br/>replica")]
        wd["Watchdog<br/>probes primary every 5 s"]
        fo["Step Functions<br/>failover runbook"]
        drill["Step Functions<br/>drill + analyzer"]
        state[("DR state / lock")]
        apiS --> auroraS & ddbS
        wd -- "3 failures" --> fo
        fo -- "FailoverGlobalCluster" --> auroraS
        fo --> state
        drill -- "start experiment" --> fis
    end

    r53 -- "PRIMARY (health: can commit writes)" --> apiP
    r53 -- "SECONDARY" --> apiS
    auroraP == "storage-level replication" ==> auroraS
    ddbP <== "global table" ==> ddbS
```

| Layer | Primary (us-east-1) | DR (us-west-2) |
|---|---|---|
| Compute | Lambda behind an HTTP API, regional custom domain | Identical, idle (pilot light costs ~$0) |
| Relational | Aurora PostgreSQL Serverless v2 writer | Global DB secondary with a warm reader |
| Key-value | DynamoDB global table replica | DynamoDB global table replica |
| Traffic | Route 53 `PRIMARY` failover record + health check | `SECONDARY` record + health check |
| Control plane | FIS experiment, fault-config bucket | Watchdog, failover/failback runbooks, drill, evidence bucket, dashboard |

## What a drill does

```mermaid
sequenceDiagram
    autonumber
    participant D as Drill (us-west-2)
    participant C as Prober (client)
    participant F as FIS (us-east-1)
    participant W as Watchdog (us-west-2)
    participant R as Failover runbook
    participant A as Aurora Global DB
    participant DNS as Route 53

    D->>C: start: POST /orders every 1 s via api-dr hostname
    Note over C: 60 s baseline, every write acknowledged by us-east-1
    D->>F: start region-impairment experiment
    F-->>C: primary Lambda now fails every request
    W->>W: 3 consecutive failed probes of primary /health
    W->>R: start failover (first_failure_at, detected_at)
    R->>R: acquire lock (PRIMARY_ACTIVE → FAILING_OVER)
    R->>A: FailoverGlobalCluster(AllowDataLoss)
    A-->>R: us-west-2 is writer
    R->>R: verify DR /health from outside → SECONDARY_ACTIVE
    DNS-->>C: secondary health check passes, DNS answers us-west-2
    C->>C: 30 consecutive acknowledged writes → recovered
    D->>D: analyzer: RTO, RPO per store, phase breakdown → result.json
    D->>F: stop experiment (optional: planned failback)
```

The drill never performs the failover itself. It breaks the primary and
watches. If the watchdog and runbook fail to recover the service, the drill
records a **FAIL**, which is the whole point.

## How RTO and RPO are measured

Measured from the client's side, never from the control plane's own report:

- **RTO**: from the first write that was *not* acknowledged to the first
  acknowledged write after recovery. It's the time a real client could not
  write, at 1 s resolution, and it includes detection, promotion, health-check
  flip and DNS TTL.
- **RPO**: a write only counts once the API returned `201 committed=true`,
  meaning both Aurora and DynamoDB accepted it. After failover the analyzer
  reads the DR region and looks for every write the old primary
  acknowledged. RPO is the largest window of acknowledged-but-missing writes;
  0 means nothing a client was told was saved got lost. Aurora and DynamoDB
  are graded separately.
- **Phase breakdown**: detection → runbook start → DB promotion →
  verification → DNS and client, built from timestamps the runbook records
  at each step.
- **Replication lag before the outage**: `AuroraGlobalDBReplicationLag`,
  `AuroraGlobalDBRPOLag` and DynamoDB `ReplicationLatency`, reported next to
  the measured loss as the theoretical exposure.

Missing evidence never counts as success:

| Situation | Verdict |
|---|---|
| Recovered via DR within the RTO target, no store over the RPO target | `PASS` |
| RTO or RPO over target, never recovered, or recovered on the primary (failover never happened) | `FAIL` |
| A store couldn't be read after failover (RPO unverifiable) | `FAIL` |
| The fault never caused a client-visible error | `INCONCLUSIVE` |

The grading logic is a pure module ([src/analyzer/rto_rpo.py](src/analyzer/rto_rpo.py))
with unit tests for each case ([tests/test_rto_rpo.py](tests/test_rto_rpo.py)).

## Design decisions

**1. Detection runs in the DR region, not on Route 53 alarms.** Route 53
health-check metrics and alarms only exist in us-east-1. Alarm-driven
failover would therefore depend on the failing region to announce its own
failure. Instead, a watchdog Lambda in us-west-2 probes the primary's
region-pinned endpoint every 5 seconds. The runbook, the drill, the state
table and the dashboard all live in the DR region too.

**2. Health means "this region can commit a write", so DNS follows the
writer.** `/health` runs a statement through the RDS Data API. Data API calls
against an Aurora global secondary fail until it is promoted, so the DR
region reports unhealthy until it really is the writer. After failover, the
old primary reports unhealthy the same way. When the fault clears, DNS
cannot flap back onto a read-only database. Failback is a deliberate,
planned switchover.

**3. Unplanned and planned paths are different APIs.** Failover uses
`FailoverGlobalCluster` with `AllowDataLoss`, because the runbook must assume
the primary is gone and cannot wait for it. Failback uses
`SwitchoverGlobalCluster` (zero data loss) and only after the old primary
reports `SynchronizationStatus = connected`.

**4. A lock prevents double failovers, and a human handles failures.** A
single DynamoDB item acts as both state machine and mutex:
`PRIMARY_ACTIVE → FAILING_OVER → SECONDARY_ACTIVE → FAILING_BACK →
PRIMARY_ACTIVE`. The watchdog only acts in `PRIMARY_ACTIVE`. A failed runbook
parks in `FAILOVER_FAILED` and pages, instead of retrying in a loop.

**5. Success is verified from outside.** The runbook only marks DR active
after a real HTTPS request to the DR endpoint commits through the full
stack.

**6. No NAT and no VPC Lambdas.** The Data API is HTTPS with IAM auth, so
the VPCs exist only for Aurora subnet groups. They have no internet path and
no inbound rules, and there are no NAT gateways to pay for.

**7. The chaos has guardrails.** The FIS experiment has a stop condition:
if neither region passes health checks for 15 minutes, the experiment aborts
and the primary is restored. The drill refuses to start unless the stack is
in `PRIMARY_ACTIVE` and the primary is healthy.

**8. Ephemeral by default.** An Aurora Global Database can't auto-pause, so
leaving it running would blow a small budget. The weekly workflow applies the
stack, drills, commits the evidence and destroys everything, so the stack
exists for about 60–90 minutes a week.

## What this does and doesn't prove

This section matters as much as the results:

- **FIS can't take down an AWS region.** The experiment simulates a region
  impairment: every primary API invocation fails, and DynamoDB replication
  out of the primary is paused. Aurora's storage-level replication keeps
  running during the drill. Aurora's measured loss therefore reflects
  in-flight lag at the moment writes stopped, which is why replication lag
  is reported next to it.
- DynamoDB pause-replication can take up to 5 minutes to take full effect
  (AWS docs), so some drills will show zero DynamoDB loss. That result is
  real, not a bug.
- The prober runs inside AWS, in the DR region. Real users' resolvers may
  cache DNS beyond the 60 s TTL, so real-world RTO for some clients can be
  longer than measured.
- The watchdog is a single vantage point. A network partition between the
  regions could look like a primary outage. In that case the primary could
  still be serving clients with cached DNS while Aurora promotes the DR
  region. That's the reason `auto_failover_enabled` exists: production
  systems often keep the runbook automated but the decision human.
- The API is unauthenticated apart from throttling. Route 53 needs a public
  `/health`, and per-region SigV4 signatures break across failover (the
  signature is bound to a region). A production system would use a
  region-agnostic JWT authorizer.

## Running it

### Prerequisites

- An AWS account with permission to create the resources in this repo
- An existing **public Route 53 hosted zone** (failover DNS needs a real domain)
- An S3 bucket for Terraform state
- Terraform ≥ 1.10, AWS CLI v2, bash (Git Bash on Windows), Python 3.12

### Manual run

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set hosted_zone_name
cp backend.hcl.example backend.hcl             # set your state bucket
terraform init -backend-config=backend.hcl
terraform apply                                # ~25-35 min, mostly Aurora Global DB

cd ..
scripts/run-drill.sh              # ~10 min; add --failback to measure the return trip too
python scripts/publish_results.py # updates docs/RESULTS.md and the table above
scripts/teardown.sh               # stops any experiment, destroys with retries
```

### Scheduled drills (GitHub Actions)

[.github/workflows/dr-drill.yml](.github/workflows/dr-drill.yml) runs every
Monday at 06:00 UTC, or on demand. It authenticates through GitHub OIDC, so
there are no stored AWS keys. It applies, drills, commits the evidence,
destroys, and fails the job if the verdict isn't `PASS`.

Configure on the repo:

| Kind | Name | Value |
|---|---|---|
| Secret | `AWS_DRILL_ROLE_ARN` | IAM role trusted for this repo via GitHub OIDC (MaxSessionDuration ≥ 4 h) |
| Variable | `HOSTED_ZONE_NAME` | e.g. `example.com` |
| Variable | `TF_STATE_BUCKET` / `TF_STATE_REGION` | Remote state location |
| Variable | `ALERT_EMAIL` | Optional: failover notifications |
| Environment | `dr-drill` | Add required reviewers if you want a human gate |

For a long-lived stack, set `drill_schedule_enabled = true` instead. The
EventBridge Scheduler then runs drills inside AWS, with failback.

### Operating it

The human runbook (manual failover, failback, resetting the lock after a
failed runbook, break-glass CLI) is in [docs/runbook.md](docs/runbook.md). The
CloudWatch dashboard is in the DR region (`terraform output dashboard_url`).

## Cost

Rough estimates, not a quote; check Cost Explorer after your first run.

| Item | While the stack exists |
|---|---|
| Aurora Serverless v2, 0.5 ACU floor × 2 regions | ≈ $0.12–0.15 / hour |
| Route 53 health checks (HTTPS, 10 s interval) × 2 | ≈ $5 / month, prorated |
| KMS keys × 2, Secrets Manager secret + replica | ≈ $3 / month, prorated |
| Lambda, API Gateway, Step Functions, DynamoDB, FIS, Data API | cents per drill |

Run weekly as an ephemeral stack (about 90 minutes each time), that comes to
roughly $0.50 per drill, or about $2–3 a month. Left running permanently, it
costs about $100 a month or more. Don't do that on a hobby budget.

## Repository layout

```
terraform/
  data.tf          Aurora Global DB, DynamoDB global table, KMS, secrets
  app.tf           both regional app stacks, Route 53 health checks + failover records
  chaos.tf         FIS experiment, fault-config bucket, stop-condition alarm
  runbook.tf       DR state/lock, watchdog, failover + failback state machines
  drill.tf         prober, analyzer, drill state machine, evidence bucket
  dashboard.tf     CloudWatch dashboard (DR region)
  modules/         network, regional-app, lambda-fn
src/
  app/             regional order API (health = "can commit a write")
  watchdog/        DR-region detector
  prober/          synthetic client, 1 acknowledged write per second
  analyzer/        RTO/RPO grading (pure logic in rto_rpo.py)
  drill_control/   cross-region FIS control + external health checks
scripts/           run-drill.sh, teardown.sh, publish_results.py
evidence/drills/   committed drill evidence (result.json + samples.jsonl)
docs/              RESULTS.md (generated), runbook.md, screenshots/
active-active/     Phase 2, self-contained
  terraform/       DSQL multi-Region cluster + peering, both regional APIs,
                   latency records + health checks, FIS, clients, analyzer, dashboard
  src/app/         regional order API on DSQL (IAM token auth, role `app`)
  src/migrate/     schema, least-privilege DB roles, IAM mappings (the only `admin` user)
  src/prober/      synthetic client, 1 write/s, EMF metrics for the dashboard
  src/analyzer/    grading (pure logic in aa_metrics.py) + read-back from both regions
  src/common/      DSQL connection helper (token auth, reconnect)
  scripts/         build.sh, run-drill.sh, teardown.sh
evidence/active-active/  committed Phase 2 drill evidence
tests/             unit tests for both graders
```
