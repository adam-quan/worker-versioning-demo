#!/usr/bin/env bash
#
# Deploy one new Worker Deployment Version and route to it in a single move.
#
#   scripts/deploy-version.sh <build-id> [ramp-percentage]
#
# With no ramp percentage the new version becomes Current immediately (100% of
# new workflow executions). With one, it becomes the Ramping version at that
# fixed percentage and stays there.
#
# For a staged rollout with health gates between steps, use
# scripts/progressive-rollout.sh instead -- that is what CI runs by default.
# This script is the manual/emergency path: fast, and unguarded.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

BUILD_ID="${1:?usage: deploy-version.sh <build-id> [ramp-percentage]}"
RAMP="${2:-}"

build_and_deploy "$BUILD_ID"

if [[ -n "$RAMP" ]]; then
  echo "==> Ramping ${RAMP}% of new executions to ${BUILD_ID}"
  kcli worker deployment set-ramping-version \
    --deployment-name "$DEPLOYMENT_NAME" --build-id "$BUILD_ID" \
    --percentage "$RAMP" --yes
else
  echo "==> Promoting ${BUILD_ID} to Current"
  # No --allow-no-pollers: if the new workers are not actually polling, the
  # server rejects the promotion and traffic stays on the old version.
  kcli worker deployment set-current-version \
    --deployment-name "$DEPLOYMENT_NAME" --build-id "$BUILD_ID" --yes
fi

print_state
