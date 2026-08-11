#!/usr/bin/env bash
#
# One-time setup: start minikube and run a Temporal dev server inside it.
set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-temporal-versioning-demo}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! minikube status >/dev/null 2>&1; then
  echo "==> Starting minikube"
  minikube start --cpus=4 --memory=4096
fi

echo "==> Deploying Temporal server"
kubectl apply -f "${REPO_ROOT}/k8s/temporal-server.yaml"
kubectl rollout status -n "$NAMESPACE" deployment/temporal --timeout=300s

cat <<'EOF'

Temporal is up inside the cluster.

To reach it from this machine (UI on :8233, gRPC on :7233):

    ./scripts/port-forward.sh

Note: do not use `minikube service --url` here -- on the `docker` driver it
blocks holding a tunnel open, and the node IP is not routable from the host.

Next: ./scripts/deploy-version.sh v1
EOF
