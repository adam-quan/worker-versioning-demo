#!/usr/bin/env bash
#
# Retire Worker Deployment Versions the server reports as `drained` -- meaning
# no open workflow is pinned to them any more, so retiring them cannot strand a
# running execution.
#
# Two things are retired for each drained version:
#
#   1. the Kubernetes Deployment running its workers
#   2. the Worker Deployment Version record on the Temporal server
#
#   scripts/cleanup-drained.sh [--dry-run] [--wait <seconds>]
#
# That order is not a choice. The server refuses `delete-version` while the
# version still has active pollers, so the pods have to go first -- and the
# server keeps poller information for a while after the last worker process
# exits (measured at roughly 5 minutes against the dev server), so the version
# delete has to be retried past that. `--wait` (default 420) bounds the
# retrying, with some margin over the observed timeout.
#
# Every drained version's pods are deleted before any version delete is
# attempted, so those poller timeouts elapse concurrently: the wait is roughly
# one timeout in total rather than one per version.
#
# A version whose pollers have not expired within --wait is reported and left on
# the server, not treated as a failure. The next run picks it up as a
# server-side leftover -- its Kubernetes Deployment is already gone by then --
# so cleanup converges. `--wait 0` leans on that deliberately: it never blocks,
# and finishes the job one run later.
#
# Versions still `draining` are left completely alone. This is the piece that
# stops old versions accumulating forever -- in Kubernetes *and* on the server.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DRY_RUN=""
WAIT="${CLEANUP_WAIT_SECONDS:-420}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --wait)    WAIT="$2"; shift 2 ;;
    *)         echo "usage: cleanup-drained.sh [--dry-run] [--wait <seconds>]" >&2; exit 2 ;;
  esac
done

# Normalised drainage status for one version:
#   drained / draining -- the server's verdict
#   ""                 -- the server has no verdict, i.e. the version is
#                         Current or Ramping and is taking new executions
#   missing            -- the server has no such version at all
drainage_status() {
  local build_id="$1" json
  json="$(kcli worker deployment describe-version \
            --deployment-name "$DEPLOYMENT_NAME" --build-id "$build_id" \
            -o json 2>/dev/null)" || { echo "missing"; return 0; }
  [[ -n "$json" ]] || { echo "missing"; return 0; }
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    status = (json.load(sys.stdin).get("drainageInfo") or {}).get("drainageStatus") or ""
except Exception:
    status = ""
# The CLI prints the short form ("drained"); tolerate the full enum name
# ("DRAINAGE_STATUS_DRAINED") in case that changes. "unspecified" carries no
# more information than an empty string.
status = status.lower().replace("drainage_status_", "")
print("" if status == "unspecified" else status)
' 2>/dev/null || echo "missing"
}

# Delete the version record on the server, retrying while the only thing in the
# way is poller information that has not expired yet.
#   0 -- gone from the server
#   2 -- still has pollers, ran out of --wait
#   1 -- the server refused for some other reason
delete_server_version() {
  local build_id="$1" deadline=$((SECONDS + WAIT)) out
  while :; do
    # Deleting an already-absent version succeeds, so this is safe to re-run.
    if out="$(kcli worker deployment delete-version \
                --deployment-name "$DEPLOYMENT_NAME" \
                --build-id "$build_id" 2>&1)"; then
      return 0
    fi
    # Anything other than pollers will not resolve itself by waiting -- e.g.
    # the version was made Current again while this script was running.
    if [[ "$out" != *"active pollers"* ]]; then
      echo "    server refused: ${out#Error: }" >&2
      return 1
    fi
    if [[ $SECONDS -ge $deadline ]]; then
      return 2
    fi
    sleep 5
  done
}

# Build IDs that have a Kubernetes Deployment. Avoid `mapfile`: stock macOS
# still ships bash 3.2, and a self-hosted runner may well use it.
k8s_build_ids="$(
  kubectl get deployments -n "$NAMESPACE" -l app=versioning-greeting-worker \
    -o jsonpath='{range .items[*]}{.metadata.labels.build-id}{"\n"}{end}' \
    | sed '/^$/d' | sort -u
)"

# Build IDs the server knows about. A version outlives its Kubernetes
# Deployment whenever an earlier run deleted the pods but could not delete the
# version yet; looking only at Kubernetes would strand those forever.
server_build_ids="$(
  kcli worker deployment describe --name "$DEPLOYMENT_NAME" -o json 2>/dev/null \
    | python3 -c '
import json, sys
try:
    summaries = json.load(sys.stdin).get("versionSummaries") or []
except Exception:
    summaries = []
for version in summaries:
    build_id = version.get("BuildID") or version.get("buildId") or ""
    if build_id and build_id != "__unversioned__":
        print(build_id)
' 2>/dev/null | sed '/^$/d' | sort -u || true
)"

build_ids="$(printf '%s\n%s\n' "$k8s_build_ids" "$server_build_ids" | sed '/^$/d' | sort -u)"

if [[ -z "$(printf '%s' "$build_ids" | tr -d '[:space:]')" ]]; then
  echo "No worker Deployments in namespace ${NAMESPACE} and no versions on the server."
  exit 0
fi

has_k8s_deployment() {
  printf '%s\n' "$k8s_build_ids" | grep -qxF "$1"
}

# ---------------------------------------------------------------------------
# Pass 1: classify every version, and delete the pods of the drained ones.
# ---------------------------------------------------------------------------
drained_build_ids=""

for build_id in $build_ids; do
  status="$(drainage_status "$build_id")"

  case "$status" in
    drained)
      drained_build_ids="${drained_build_ids}${build_id}"$'\n'
      if has_k8s_deployment "$build_id"; then
        if [[ -n "$DRY_RUN" ]]; then
          echo "would delete Kubernetes Deployment worker-${build_id} (drained)"
        else
          echo "deleting Kubernetes Deployment worker-${build_id} (drained)"
          kubectl delete deployment -n "$NAMESPACE" "worker-${build_id}"
        fi
      else
        echo "worker-${build_id}: drained, Kubernetes Deployment already gone"
      fi
      ;;
    draining)
      echo "keeping worker-${build_id} (still draining -- workflows are pinned to it)"
      ;;
    missing)
      # No version record but pods exist: the workers re-register the version as
      # soon as they poll, so deleting them here would be wrong.
      if has_k8s_deployment "$build_id"; then
        echo "keeping worker-${build_id} (no version on the server yet -- workers still registering)"
      fi
      ;;
    *)
      # An empty status means the version is Current or Ramping.
      echo "keeping worker-${build_id} (current/ramping or not yet drained)"
      ;;
  esac
done

if [[ -z "$(printf '%s' "$drained_build_ids" | tr -d '[:space:]')" ]]; then
  echo
  echo "Nothing drained; no versions to retire."
  exit 0
fi

# ---------------------------------------------------------------------------
# Pass 2: no drained version has pods any more, so delete the version records.
# ---------------------------------------------------------------------------
echo

if [[ -n "$DRY_RUN" ]]; then
  for build_id in $drained_build_ids; do
    echo "would delete Worker Deployment Version ${DEPLOYMENT_NAME}:${build_id}"
  done
  exit 0
fi

# Wait for the pods themselves to go, not just the Deployment object. Workers
# get a graceful shutdown period, and their poller registration cannot start
# expiring until the processes actually exit.
for build_id in $drained_build_ids; do
  kubectl wait --for=delete pod -n "$NAMESPACE" \
    -l "build-id=${build_id}" --timeout=60s >/dev/null 2>&1 || true
done

exit_code=0
left_behind=""

for build_id in $drained_build_ids; do
  echo "deleting Worker Deployment Version ${DEPLOYMENT_NAME}:${build_id}"
  set +e
  delete_server_version "$build_id"
  result=$?
  set -e
  case "$result" in
    0) echo "    version deleted from the server" ;;
    2) left_behind="${left_behind}  ${DEPLOYMENT_NAME}:${build_id}"$'\n'
       echo "    still has active pollers after ${WAIT}s -- leaving it for the next run" ;;
    *) exit_code=1 ;;
  esac
done

if [[ -n "$left_behind" ]]; then
  echo
  echo "Left on the server (their pods are gone, so the next run deletes them):"
  printf '%s' "$left_behind"
fi

exit "$exit_code"
