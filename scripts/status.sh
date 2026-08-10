#!/usr/bin/env bash
#
# Show, side by side, what Temporal thinks the versions are and what is
# actually running in Kubernetes.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "=== Worker Deployment: ${DEPLOYMENT_NAME} ==="
tcli worker deployment describe --name "$DEPLOYMENT_NAME"

echo
echo "=== Per-version drainage ==="
printf '%-20s %-12s %s\n' "BUILD ID" "DRAINAGE" "MEANING"
kubectl get deployments -n "$NAMESPACE" -l app=greeting-worker \
  -o jsonpath='{range .items[*]}{.metadata.labels.build-id}{"\n"}{end}' | sort -u |
while read -r build_id; do
  [[ -z "$build_id" ]] && continue
  status="$(
    tcli worker deployment describe-version \
      --deployment-name "$DEPLOYMENT_NAME" --build-id "$build_id" -o json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["drainageInfo"]["drainageStatus"])' \
      2>/dev/null || echo "unknown"
  )"
  case "$status" in
    draining) meaning="workflows still pinned here -- keep the pods" ;;
    drained)  meaning="safe to delete (scripts/cleanup-drained.sh)" ;;
    "")       meaning="current or ramping -- taking new executions" ;;
    *)        meaning="-" ;;
  esac
  printf '%-20s %-12s %s\n' "$build_id" "${status:-none}" "$meaning"
done

echo
echo "=== Kubernetes ==="
kubectl get deployments -n "$NAMESPACE" -l app=greeting-worker -L build-id
