#!/usr/bin/env bash
# Destroy the stack, tolerating the states a drill leaves behind.
#
# After an unplanned failover the old primary is being rebuilt as a secondary;
# RDS can reject deletes while a member is mid-resync, so destroy is retried.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TFDIR="$ROOT/terraform"

# Stop any FIS experiment still running so it doesn't hold targets.
if PRIMARY="$(terraform -chdir="$TFDIR" output -raw primary_region 2>/dev/null)" &&
   TEMPLATE="$(terraform -chdir="$TFDIR" output -raw fis_experiment_template_id 2>/dev/null)"; then
  for id in $(aws fis list-experiments --region "$PRIMARY" \
      --query "experiments[?experimentTemplateId=='${TEMPLATE}' && contains(['pending','initiating','running'], state.status)].id" \
      --output text 2>/dev/null); do
    echo "stopping FIS experiment ${id}"
    aws fis stop-experiment --region "$PRIMARY" --id "$id" >/dev/null || true
  done
fi

# Detach every cluster from the global database first. After an unplanned
# failover the writer may be the "secondary" Terraform resource, and RDS will
# not delete the writer instance of a global primary that still has members.
# Detached clusters are plain regional clusters Terraform can delete in order.
if GLOBAL="$(terraform -chdir="$TFDIR" output -raw global_cluster_id 2>/dev/null)" &&
   SECONDARY="$(terraform -chdir="$TFDIR" output -raw secondary_region 2>/dev/null)"; then
  members="$(aws rds describe-global-clusters --region "$SECONDARY" --global-cluster-identifier "$GLOBAL" \
    --query 'GlobalClusters[0].GlobalClusterMembers[].[IsWriter,DBClusterArn]' --output text 2>/dev/null || true)"
  # readers (False) before the writer (True)
  for arn in $(echo "$members" | sort | awk '{print $2}'); do
    region="$(echo "$arn" | cut -d: -f4)"
    echo "detaching ${arn} from ${GLOBAL}"
    aws rds remove-from-global-cluster --region "$region" \
      --global-cluster-identifier "$GLOBAL" --db-cluster-identifier "$arn" >/dev/null || true
  done
  for arn in $(echo "$members" | awk '{print $2}'); do
    region="$(echo "$arn" | cut -d: -f4)"
    aws rds wait db-cluster-available --region "$region" --db-cluster-identifier "$arn" 2>/dev/null || true
  done
fi

for attempt in 1 2 3; do
  echo "terraform destroy (attempt ${attempt})"
  if terraform -chdir="$TFDIR" destroy -auto-approve -input=false "$@"; then
    echo "destroyed"; exit 0
  fi
  echo "destroy failed; waiting 120 s for RDS to settle" >&2
  sleep 120
done

echo "destroy failed 3 times - check for orphaned Aurora clusters and stop billing manually" >&2
exit 1
