# DR operations runbook

Everything here runs against the **DR region** (default `us-west-2`), because
that is the region you can count on reaching when the primary is in trouble.
Set these first:

```bash
cd terraform
export DR_REGION=$(terraform output -raw secondary_region)
export STATE_TABLE=$(terraform output -raw dr_state_table)
export FAILOVER_SM=$(terraform output -raw failover_state_machine_arn)
export FAILBACK_SM=$(terraform output -raw failback_state_machine_arn)
export GLOBAL_DB=$(terraform output -raw global_cluster_id)
```

## 1. Where are we?

```bash
aws dynamodb get-item --region "$DR_REGION" --table-name "$STATE_TABLE" \
  --key '{"pk":{"S":"failover"}}' --consistent-read --output json

aws rds describe-global-clusters --region "$DR_REGION" --global-cluster-identifier "$GLOBAL_DB" \
  --query 'GlobalClusters[0].{status:Status,members:GlobalClusterMembers[].{arn:DBClusterArn,writer:IsWriter,sync:SynchronizationStatus}}'
```

| `state` | Meaning | Watchdog |
|---|---|---|
| `PRIMARY_ACTIVE` | Normal operation | armed |
| `FAILING_OVER` | Failover runbook in flight | idle |
| `SECONDARY_ACTIVE` | Serving from DR | idle |
| `FAILING_BACK` | Planned switchover in flight | idle |
| `FAILOVER_FAILED` / `FAILBACK_FAILED` | Runbook gave up; `last_error` says why | idle until reset |

## 2. Fail over manually

Use this when the watchdog is disabled (`auto_failover_enabled = false`) or
when you want to fail over before it would on its own.

```bash
aws stepfunctions start-execution --region "$DR_REGION" --state-machine-arn "$FAILOVER_SM" \
  --name "manual-$(date -u +%Y%m%dT%H%M%SZ)" --input '{"reason":"manual: <who / why>"}'
```

The runbook takes the lock, promotes the DR cluster, verifies the DR
`/health` endpoint from outside, and marks the state `SECONDARY_ACTIVE`.
Route 53 moves traffic as soon as the DR health check passes.

## 3. Fail back (planned, zero data loss)

Only do this once the primary region is healthy again. The runbook waits for
the old primary to finish resynchronising (this can take tens of minutes
after an unplanned failover), then runs a switchover.

```bash
aws stepfunctions start-execution --region "$DR_REGION" --state-machine-arn "$FAILBACK_SM" \
  --name "failback-$(date -u +%Y%m%dT%H%M%SZ)" --input '{"reason":"manual failback"}'
```

## 4. Reset after a failed runbook

1. Read `last_error` on the state item (section 1) and the execution history
   in the Step Functions console.
2. Fix the cause, then set the state to match reality: `PRIMARY_ACTIVE` if
   the primary is still the writer, `SECONDARY_ACTIVE` if the DR cluster is.

```bash
aws dynamodb update-item --region "$DR_REGION" --table-name "$STATE_TABLE" \
  --key '{"pk":{"S":"failover"}}' \
  --update-expression 'SET #s = :s REMOVE last_error' \
  --expression-attribute-names '{"#s":"state"}' \
  --expression-attribute-values '{":s":{"S":"PRIMARY_ACTIVE"}}'
```

## 5. Break glass: Step Functions unavailable

The runbook is a convenience, not a dependency. The underlying operation is
a single call:

```bash
aws rds failover-global-cluster --region "$DR_REGION" \
  --global-cluster-identifier "$GLOBAL_DB" \
  --target-db-cluster-identifier "$(terraform output -raw secondary_cluster_arn)" \
  --allow-data-loss
```

Then update the state item to `SECONDARY_ACTIVE` (section 4), so the watchdog
doesn't act on a primary that is no longer the writer.

## 6. Stop automation

```bash
# Disable automatic failover (the runbook stays available for manual use)
terraform apply -var auto_failover_enabled=false

# Abort a running drill: stop the execution, then stop its FIS experiment
aws stepfunctions stop-execution --region "$DR_REGION" --execution-arn <drill-execution-arn>
aws fis list-experiments --region "$(terraform output -raw primary_region)" \
  --query "experiments[?state.status=='running'].id"
aws fis stop-experiment --region "$(terraform output -raw primary_region)" --id <experiment-id>
```

The FIS experiment also stops on its own when the `no-healthy-region` alarm
fires (neither region healthy for 15 minutes), or when the fault duration
expires.
