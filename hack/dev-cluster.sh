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
# Use BEAM clustering for distributed supervision with automatic failover
helm upgrade --install nopea ./charts/nopea \
    --namespace nopea-system \
    --create-namespace \
    --set image.repository=nopea \
    --set image.tag=dev \
    --set image.pullPolicy=Never \
    --set replicas=2 \
    --set cluster.enabled=true \
    --set cluster.cookie=nopea_dev_cluster_cookie \
    --wait \
    --timeout=120s

echo ""
echo "==> Deployment complete!"
echo ""
echo "Pod status:"
kubectl -n nopea-system get pods -o wide
echo ""
echo "Headless service (for node discovery):"
kubectl -n nopea-system get svc nopea-headless
echo ""
echo "==> Checking cluster connectivity..."
sleep 5
# Get first pod and check if it sees other nodes
FIRST_POD=$(kubectl -n nopea-system get pods -l app.kubernetes.io/name=nopea -o jsonpath='{.items[0].metadata.name}')
echo "Nodes visible from ${FIRST_POD}:"
kubectl -n nopea-system exec "${FIRST_POD}" -- bin/nopea rpc "Node.list()" 2>/dev/null || echo "(Node.list check requires shell access)"
echo ""
echo "To view logs:"
echo "  kubectl -n nopea-system logs -l app.kubernetes.io/name=nopea -f"
echo ""
echo "To check cluster status:"
echo "  kubectl -n nopea-system exec -it ${FIRST_POD} -- bin/nopea remote"
