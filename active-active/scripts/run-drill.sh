#!/usr/bin/env bash
# Run one active-active drill against the deployed stack and pull the evidence.
#
#   active-active/scripts/run-drill.sh
#
# Timeline: both clients start -> 60 s baseline -> FIS fails every east API
# call for 5 min -> fault ends -> clients keep writing until ~11 min total ->
# analyzer grades the run, reading every write back from BOTH regions.
#
# Exit codes: 0 = drill ran (see verdict), 2 = drill errored, 3 = preflight failed.
set -euo pipefail

AA="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$AA/.." && pwd)"
# cd rather than -chdir: terraform.exe on Windows cannot parse Git Bash paths.
tf() { (cd "$AA/terraform" && terraform output -raw "$1"); }

API_URL="$(tf api_url)"
EAST="$(tf east_region)"
WEST="$(tf west_region)"
WITNESS="$(tf witness_region)"
BUCKET="$(tf evidence_bucket)"
PROBER_EAST="$(tf prober_east_name)"
PROBER_WEST="$(tf prober_west_name)"
ANALYZER="$(tf analyzer_name)"
TEMPLATE="$(tf fis_template_id)"
RUN_ID="aa-drill-$(date -u +%Y%m%dT%H%M%SZ)"
BASELINE_SECONDS=60
CLIENT_SECONDS=660

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# --- Preflight: both regions and the public hostname must be serving.
echo "preflight: waiting for both regions and ${API_URL} to pass /health 5x in a row"
for url in "$(tf east_health_url)" "$(tf west_health_url)" "${API_URL}/health"; do
  ok=0
  for _ in $(seq 1 120); do
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      ok=$((ok + 1)); [[ $ok -ge 5 ]] && break
    else
      ok=0
    fi
    sleep 5
  done
  if [[ $ok -lt 5 ]]; then
    echo "preflight failed: $url not consistently healthy after 10 minutes" >&2
    exit 3
  fi
  echo "  ok: $url"
done

echo "starting ${RUN_ID}"
PAYLOAD="{\"run_id\": \"${RUN_ID}\", \"duration_seconds\": ${CLIENT_SECONDS}}"
for pair in "$PROBER_EAST:$WITNESS" "$PROBER_WEST:$WEST"; do
  fn="${pair%%:*}"; region="${pair##*:}"
  aws lambda invoke --region "$region" --function-name "$fn" --invocation-type Event \
    --cli-binary-format raw-in-base64-out --payload "$PAYLOAD" "$(native "$SCRATCH/$fn.out")" >/dev/null
  echo "  client started: $fn ($region)"
done

echo "baseline: ${BASELINE_SECONDS}s of normal traffic"
sleep "$BASELINE_SECONDS"

EXPERIMENT_ID="$(aws fis start-experiment --region "$EAST" \
  --experiment-template-id "$TEMPLATE" \
  --tags "run_id=${RUN_ID}" \
  --query experiment.id --output text)"
echo "fault injected: FIS experiment ${EXPERIMENT_ID} (${EAST} API fails every call)"

# --- Wait for the experiment to finish and both clients to upload samples.
deadline=$(( $(date +%s) + 20 * 60 ))
state=""
while :; do
  state="$(aws fis get-experiment --region "$EAST" --id "$EXPERIMENT_ID" --query experiment.state.status --output text)"
  have=0
  for c in east west; do
    aws s3api head-object --region "$WEST" --bucket "$BUCKET" --key "drills/${RUN_ID}/samples-${c}.jsonl" >/dev/null 2>&1 && have=$((have + 1))
  done
  if [[ "$state" =~ ^(completed|stopped|failed)$ && $have -eq 2 ]]; then
    break
  fi
  if [[ $(date +%s) -gt $deadline ]]; then
    echo "drill did not finish within 20 minutes (experiment ${state}, ${have}/2 client uploads)" >&2
    aws fis stop-experiment --region "$EAST" --id "$EXPERIMENT_ID" >/dev/null 2>&1 || true
    exit 2
  fi
  printf '.'; sleep 30
done
echo; echo "experiment ${state}; both clients finished"

echo "grading"
aws lambda invoke --region "$WEST" --function-name "$ANALYZER" \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"run_id\": \"${RUN_ID}\", \"experiment_id\": \"${EXPERIMENT_ID}\", \"clients\": [\"east\", \"west\"]}" \
  "$(native "$SCRATCH/analyzer.out")" >/dev/null

DEST="$ROOT/evidence/active-active/$RUN_ID"
mkdir -p "$DEST"
aws s3 cp --region "$WEST" --recursive --only-show-errors "s3://${BUCKET}/drills/${RUN_ID}/" "$(native "$DEST")/"
aws fis get-experiment --region "$EAST" --id "$EXPERIMENT_ID" --output json > "$DEST/fis-experiment.json"

if [[ ! -f "$DEST/result.json" ]]; then
  echo "no result.json produced - analyzer errored:" >&2
  cat "$SCRATCH/analyzer.out" >&2 || true
  exit 2
fi

PY_BIN="$(command -v python || command -v python3)"
"$PY_BIN" - "$(native "$DEST/result.json")" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
h = r["headline"]
print(f"verdict: {r['verdict']}")
print(f"east client longest outage: {h['impacted_client_max_outage_seconds']} s  (target {r['targets']['max_outage_seconds']} s)")
print(f"east client moved to west after: {h['rerouted_after_seconds']} s; back home {h['returned_home_after_seconds']} s after fault ended")
print(f"west client failed writes: {h['unaffected_client_failed_writes']}")
print(f"acknowledged writes: {h['acked_writes']}, lost: {h['lost_acked_writes']}")
for name, c in r["clients"].items():
    print(f"  {name:<5} home {c['home_region']}  availability {c['availability_pct']}%  latency p50 {c['latency_ms']['baseline_p50']} ms")
for reason in r.get("reasons", []):
    print(f"  ! {reason}")
PY
