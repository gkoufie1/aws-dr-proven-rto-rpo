#!/usr/bin/env bash
# Destroy the active-active stack. Stops any running FIS experiment first so
# the destroy is not racing a fault against the east Lambda.
set -euo pipefail

AA="$(cd "$(dirname "$0")/.." && pwd)"
tf() { (cd "$AA/terraform" && terraform "$@"); }

EAST="$(tf output -raw east_region 2>/dev/null || echo us-east-1)"
TEMPLATE="$(tf output -raw fis_template_id 2>/dev/null || true)"
if [[ -n "$TEMPLATE" ]]; then
  for id in $(aws fis list-experiments --region "$EAST" \
      --query "experiments[?experimentTemplateId=='${TEMPLATE}' && contains(['pending','initiating','running'], state.status)].id" \
      --output text); do
    echo "stopping FIS experiment $id"
    aws fis stop-experiment --region "$EAST" --id "$id" >/dev/null || true
  done
fi

bash "$AA/scripts/build.sh" >/dev/null   # archive_file needs the build dirs to exist

for attempt in 1 2 3; do
  if tf destroy -auto-approve -input=false; then
    echo "destroyed"
    exit 0
  fi
  echo "destroy attempt $attempt failed; retrying in 60 s" >&2
  sleep 60
done
exit 1
