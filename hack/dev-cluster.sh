#!/bin/bash
set -euo pipefail

CLUSTER_NAME="nopea-dev"
IMAGE_NAME="nopea:dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Checking for Kind cluster..."
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "==> Creating Kind cluster..."
    kind create cluster --name "${CLUSTER_NAME}" --config hack/kind-config.yaml
else
    echo "==> Kind cluster '${CLUSTER_NAME}' already exists"
fi

echo "==> Building Docker image..."
docker build -t "${IMAGE_NAME}" .

echo "==> Loading image into Kind..."
kind load docker-image "${IMAGE_NAME}" --name "${CLUSTER_NAME}"

echo "==> Installing with Helm..."
# Note: Don't use --wait with leader election - only 1 replica will be Ready
helm upgrade --install nopea ./charts/nopea \
    --namespace nopea-system \
    --create-namespace \
    --set image.repository=nopea \
    --set image.tag=dev \
    --set image.pullPolicy=Never \
    --set replicas=2 \
    --set leaderElection.enabled=true

echo ""
echo "==> Deployment complete!"
echo ""
echo "Leader election status:"
kubectl -n nopea-system get lease nopea-leader-election -o yaml 2>/dev/null || echo "(Lease not yet created - waiting for leader election)"
echo ""
echo "Pod status:"
kubectl -n nopea-system get pods
echo ""
echo "To view logs:"
echo "  kubectl -n nopea-system logs -l app.kubernetes.io/name=nopea -f"
