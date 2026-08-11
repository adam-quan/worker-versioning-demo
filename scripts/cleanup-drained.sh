#!/usr/bin/env bash
#
# Delete the Kubernetes Deployments for Worker Deployment Versions the server
# reports as `drained` -- meaning no open workflow is pinned to them any more,
# so removing those workers cannot strand a running execution.
#
#   scripts/cleanup-drained.sh [--dry-run]
#
# Versions still `draining` are left alone on purpose. This is the piece that
# stops old versions accumulating forever.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Avoid `mapfile`: stock macOS still ships bash 3.2, and a self-hosted runner
# may well use it.
build_ids="$(
  kubectl get deployments -n "$NAMESPACE" -l app=versioning-greeting-worker \
    -o jsonpath='{range .items[*]}{.metadata.labels.build-id}{"\n"}{end}' | sort -u
)"

if [[ -z "$(echo "$build_ids" | tr -d '[:space:]')" ]]; then
  echo "No worker Deployments found in namespace ${NAMESPACE}."
  exit 0
fi

for build_id in $build_ids; do
  [[ -z "$build_id" ]] && continue

  status="$(
    tcli worker deployment describe-version \
      --deployment-name "$DEPLOYMENT_NAME" --build-id "$build_id" -o json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["drainageInfo"]["drainageStatus"])' \
      2>/dev/null || echo "unknown"
  )"

  case "$status" in
    drained)
      if [[ -n "$DRY_RUN" ]]; then
        echo "would delete worker-${build_id} (drained)"
      else
        echo "deleting worker-${build_id} (drained)"
        kubectl delete deployment -n "$NAMESPACE" "worker-${build_id}"
      fi
      ;;
    draining)
      echo "keeping worker-${build_id} (still draining -- workflows are pinned to it)"
      ;;
    *)
      # An empty status means the version is Current or Ramping.
      echo "keeping worker-${build_id} (current/ramping or not yet drained)"
      ;;
  esac
done
