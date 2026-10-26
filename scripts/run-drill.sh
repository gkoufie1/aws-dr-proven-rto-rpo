#!/usr/bin/env bash
# Run one DR drill against the deployed stack and pull the evidence locally.
#
#   scripts/run-drill.sh              # drill, no failback (stack will be destroyed)
#   scripts/run-drill.sh --failback   # drill + planned switchover back to primary
#
# Exit codes: 0 = drill ran (see verdict), 2 = drill errored, 3 = preflight failed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tf() { terraform -chdir="$ROOT/terraform" output -raw "$1"; }

FAILBACK=false
[[ "${1:-}" == "--failback" ]] && FAILBACK=true

SM_ARN="$(tf drill_state_machine_arn)"
REGION="$(tf secondary_region)"
BUCKET="$(tf evidence_bucket)"
API_URL="$(tf api_url)"
RUN_ID="drill-$(date -u +%Y%m%dT%H%M%SZ)"

# --- Preflight: the public hostname must be serving before we break anything.
# Fresh stacks need a few minutes for ACM, the custom domain and DNS to settle.
echo "preflight: waiting for ${API_URL}/health to pass 5x in a row"
ok=0
for _ in $(seq 1 120); do
  if curl -fsS --max-time 5 "${API_URL}/health" >/dev/null 2>&1; then
    ok=$((ok + 1)); [[ $ok -ge 5 ]] && break
  else
    ok=0
  fi
  sleep 5
done
if [[ $ok -lt 5 ]]; then
  echo "preflight failed: ${API_URL}/health not consistently healthy after 10 minutes" >&2
  exit 3
fi

echo "starting ${RUN_ID} (failback=${FAILBACK})"
EXEC_ARN="$(aws stepfunctions start-execution \
  --region "$REGION" \
  --state-machine-arn "$SM_ARN" \
  --name "$RUN_ID" \
  --input "{\"failback\": ${FAILBACK}}" \
  --query executionArn --output text)"

max_minutes=30; $FAILBACK && max_minutes=150
deadline=$(( $(date +%s) + max_minutes * 60 ))
while :; do
  status="$(aws stepfunctions describe-execution --region "$REGION" --execution-arn "$EXEC_ARN" --query status --output text)"
  [[ "$status" != "RUNNING" ]] && break
  if [[ $(date +%s) -gt $deadline ]]; then
    echo "drill still running after ${max_minutes} min - stopping it" >&2
    aws stepfunctions stop-execution --region "$REGION" --execution-arn "$EXEC_ARN" >/dev/null
    status="TIMED_OUT"; break
  fi
  printf '.'; sleep 30
done
echo; echo "execution status: ${status}"

DEST="$ROOT/evidence/drills/$RUN_ID"
mkdir -p "$DEST"
aws s3 cp --region "$REGION" --recursive --only-show-errors "s3://${BUCKET}/drills/${RUN_ID}/" "$DEST/" || true

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "run_id=${RUN_ID}" >> "$GITHUB_OUTPUT"
fi

if [[ ! -f "$DEST/result.json" ]]; then
  echo "no result.json produced - drill errored before grading" >&2
  aws stepfunctions describe-execution --region "$REGION" --execution-arn "$EXEC_ARN" --query '[error,cause]' --output text >&2 || true
  exit 2
fi

python3 - "$DEST/result.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"verdict: {r['verdict']}")
print(f"RTO (user-observed): {r['rto_seconds']} s   target {r['targets']['rto_seconds']} s")
print(f"RPO:                 {r['rpo_seconds']} s   target {r['targets']['rpo_seconds']} s")
for k, v in (r.get("phases") or {}).items():
    print(f"  {k:<22} {v}")
for reason in r.get("reasons", []):
    print(f"  ! {reason}")
PY

[[ "$status" == "SUCCEEDED" ]] || exit 2
