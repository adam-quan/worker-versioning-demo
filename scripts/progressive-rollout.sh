#!/usr/bin/env bash
#
# Progressively roll a new Worker Deployment Version into service.
#
#   scripts/progressive-rollout.sh <build-id> [--steps 5,25,50] [--bake 60]
#                                             [--max-failures 0] [--no-build]
#
# Instead of flipping 100% of new workflow executions onto a new version in one
# move, this walks the Ramping Version up through a series of percentages,
# pausing at each to check the version's health, and only makes it Current once
# every step has passed:
#
#     deploy (0%) -> 5% -> 25% -> 50% -> Current (100%)
#                     |      |      |
#                     +------+------+--- health gate; failure rolls back
#
# Rolling back means deleting the ramp, which sends *new* executions straight
# back to the old Current version. Executions already started on the new
# version keep running on it -- their workers are deliberately left up.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

BUILD_ID=""
STEPS="${ROLLOUT_STEPS:-5,25,50}"
BAKE="${ROLLOUT_BAKE_SECONDS:-60}"
MAX_FAILURES="${ROLLOUT_MAX_FAILURES:-0}"
DO_BUILD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --steps)         STEPS="$2"; shift 2 ;;
    --bake)          BAKE="$2"; shift 2 ;;
    --max-failures)  MAX_FAILURES="$2"; shift 2 ;;
    --no-build)      DO_BUILD=0; shift ;;
    -*)              echo "unknown flag: $1" >&2; exit 2 ;;
    *)               BUILD_ID="$1"; shift ;;
  esac
done

[[ -n "$BUILD_ID" ]] || {
  echo "usage: progressive-rollout.sh <build-id> [--steps 5,25,50] [--bake 60]" >&2
  exit 2
}

rollback() {
  local reason="$1"
  echo
  echo "!! ROLLING BACK: ${reason}" >&2
  # Remove the ramp. New executions immediately go back to the Current version;
  # the new version's pods stay up for anything already pinned to them.
  #
  # Note the absent --build-id: `--delete --build-id X` only zeroes X's
  # percentage and leaves X installed as the ramping version, which stops it
  # ever reporting `drained` -- so cleanup-drained.sh could never retire it.
  # Deleting without a Build ID clears the slot properly.
  tcli worker deployment set-ramping-version \
    --deployment-name "$DEPLOYMENT_NAME" --delete --yes >&2 || true
  echo "   ramp removed; ${BUILD_ID} is receiving no new executions." >&2
  echo "   its pods are left running for executions already started on it." >&2
  echo "   inspect with: kubectl logs -n ${NAMESPACE} deploy/worker-${BUILD_ID}" >&2
  exit 1
}

# A version is healthy if its pods are all up and the executions routed to it
# are not failing. Both matter: a crash-looping worker shows up in the first,
# a workflow that breaks only on the new code shows up in the second.
health_check() {
  local step="$1"

  local desired ready
  desired="$(kubectl get deployment -n "$NAMESPACE" "worker-${BUILD_ID}" -o jsonpath='{.spec.replicas}')"
  ready="$(kubectl get deployment -n "$NAMESPACE" "worker-${BUILD_ID}" -o jsonpath='{.status.readyReplicas}')"
  ready="${ready:-0}"
  if [[ "$ready" != "$desired" ]]; then
    rollback "at ${step}%, only ${ready}/${desired} worker pods are ready"
  fi

  local restarts
  restarts="$(kubectl get pods -n "$NAMESPACE" -l "build-id=${BUILD_ID}" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
    | awk '{s+=$1} END {print s+0}')"
  if [[ "$restarts" -gt 0 ]]; then
    rollback "at ${step}%, worker pods have restarted ${restarts} time(s)"
  fi

  # The version must still be polling; if every worker died the server would
  # keep routing this percentage into a black hole.
  tcli worker deployment describe-version \
    --deployment-name "$DEPLOYMENT_NAME" --build-id "$BUILD_ID" >/dev/null 2>&1 \
    || rollback "at ${step}%, version is no longer registered with the server"

  local total failed
  total="$(count_executions "$BUILD_ID")"
  failed="$(count_executions "$BUILD_ID" "ExecutionStatus='Failed' OR ExecutionStatus='Terminated'")"
  echo "    health: ${ready}/${desired} pods ready, ${total} execution(s) routed, ${failed} failed"

  if [[ "${failed:-0}" -gt "$MAX_FAILURES" ]]; then
    rollback "at ${step}%, ${failed} execution(s) failed on ${BUILD_ID} (max ${MAX_FAILURES})"
  fi
}

echo "==> Progressive rollout of ${DEPLOYMENT_NAME}:${BUILD_ID}"
echo "    steps: ${STEPS}%  bake: ${BAKE}s per step  failure budget: ${MAX_FAILURES}"

if [[ "$DO_BUILD" -eq 1 ]]; then
  build_and_deploy "$BUILD_ID"
else
  echo "==> Skipping build (--no-build)"
fi

# Ramping splits traffic between the Current version and this one. On a fresh
# deployment there is no Current version to split against, so there is nothing
# to roll out progressively -- go straight to Current.
current_build="$(
  tcli worker deployment describe --name "$DEPLOYMENT_NAME" -o json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("routingConfig", d).get("currentVersionBuildID", "") or "")
except Exception:
    print("")' 2>/dev/null || echo ""
)"

if [[ -z "$current_build" || "$current_build" == "__unversioned__" ]]; then
  echo
  echo "==> No Current version yet; nothing to ramp against."
  echo "    Promoting ${BUILD_ID} to Current directly."
  tcli worker deployment set-current-version \
    --deployment-name "$DEPLOYMENT_NAME" --build-id "$BUILD_ID" --yes
  print_state
  exit 0
fi

IFS=',' read -r -a step_list <<< "$STEPS"
for step in "${step_list[@]}"; do
  step="$(echo "$step" | tr -d '[:space:]')"
  [[ -z "$step" ]] && continue

  echo
  echo "==> Ramping to ${step}% of new executions"
  tcli worker deployment set-ramping-version \
    --deployment-name "$DEPLOYMENT_NAME" --build-id "$BUILD_ID" \
    --percentage "$step" --yes

  echo "    baking for ${BAKE}s"
  sleep "$BAKE"
  health_check "$step"
done

echo
echo "==> All steps passed; promoting ${BUILD_ID} to Current"
# Promoting clears the ramp automatically -- the version goes to 100%.
# No --allow-no-pollers: if the workers stopped polling, this fails and the
# old version stays Current.
tcli worker deployment set-current-version \
  --deployment-name "$DEPLOYMENT_NAME" --build-id "$BUILD_ID" --yes

print_state
