#!/usr/bin/env bash
#
# Shared configuration and helpers. Sourced by the other scripts; not run
# directly.

DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-versioning-greeting-worker}"
TASK_QUEUE="${TASK_QUEUE:-versioning-greeting-tq}"
NAMESPACE="${K8S_NAMESPACE:-temporal-versioning-demo}"
REPLICAS="${REPLICAS:-2}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run the Temporal CLI inside the server pod, via kubectl. The image already
# ships the CLI, so CI needs no extra tooling and no network path into the
# cluster.
#
# Named for the `kubectl` it goes through, and deliberately not anything close
# to `tctl` -- that is the *deprecated* CLI, which this repo does not use.
kcli() {
  kubectl exec -n "$NAMESPACE" deploy/temporal -- \
    temporal --address localhost:7233 "$@"
}

# Build the image for a Build ID and bring up its own Kubernetes Deployment.
# Deliberately changes NO routing: the new workers poll, but the server sends
# them nothing until something makes the version Current or Ramping.
build_and_deploy() {
  local build_id="$1"
  local image="worker-versioning-demo:${build_id}"

  echo "==> Building image ${image} inside minikube's Docker daemon"
  # Build directly into the cluster's daemon so there is no registry to push to.
  eval "$(minikube docker-env)"
  docker build \
    --build-arg "BUILD_ID=${build_id}" \
    -t "${image}" \
    "${REPO_ROOT}/worker"

  echo "==> Applying Kubernetes Deployment worker-${build_id}"
  # A NEW Deployment per Build ID. Older versions stay up to serve their PINNED
  # workflows; nothing about them is modified here.
  BUILD_ID="$build_id" IMAGE="$image" REPLICAS="$REPLICAS" \
  DEPLOYMENT_NAME="$DEPLOYMENT_NAME" TASK_QUEUE="$TASK_QUEUE" \
    envsubst < "${REPO_ROOT}/k8s/worker-deployment.template.yaml" \
    | kubectl apply -f -

  kubectl rollout status -n "$NAMESPACE" "deployment/worker-${build_id}" --timeout=180s

  echo "==> Waiting for build ${build_id} to register with the Temporal server"
  # A version exists on the server only once a worker with that Build ID polls.
  # Routing to it before then would fail, so wait for it to show up.
  local attempt
  for attempt in $(seq 1 60); do
    if kcli worker deployment describe-version \
        --deployment-name "$DEPLOYMENT_NAME" --build-id "$build_id" >/dev/null 2>&1; then
      echo "    registered after ${attempt} attempt(s)"
      return 0
    fi
    if [[ $attempt -eq 60 ]]; then
      echo "ERROR: build ${build_id} never registered; workers are not polling." >&2
      kubectl logs -n "$NAMESPACE" "deployment/worker-${build_id}" --tail=50 >&2 || true
      return 1
    fi
    sleep 2
  done
}

# How many workflow executions the server attributes to this version, and how
# many of them ended badly. The `TemporalWorkerDeploymentVersion` search
# attribute is set by the server, so this measures real routed traffic.
count_executions() {
  local build_id="$1" extra="${2:-}"
  local query="TemporalWorkerDeploymentVersion='${DEPLOYMENT_NAME}:${build_id}'"
  [[ -n "$extra" ]] && query="${query} AND ${extra}"
  kcli workflow count --query "$query" 2>/dev/null \
    | awk '/^Total:/ {print $2; found=1} END {if (!found) print 0}'
}

print_state() {
  echo
  echo "==> Worker Deployment state"
  kcli worker deployment describe --name "$DEPLOYMENT_NAME"
  echo
  echo "==> Worker Deployments running in Kubernetes"
  kubectl get deployments -n "$NAMESPACE" -l app=versioning-greeting-worker -L build-id
}
