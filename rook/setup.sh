#!/usr/bin/env bash
set -euo pipefail

# Install a version-pinned Rook operator, Ceph-CSI operator, and Ceph cluster.
# The preflight is deliberately run first because creating OSDs destroys data on
# each selected device.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_FILE="$ROOT_DIR/kubeconfig"
ROOK_VERSION="v1.21.1"
ROOK_NAMESPACE="rook-ceph"
ROOK_BASE_URL="https://raw.githubusercontent.com/rook/rook/$ROOK_VERSION/deploy/examples"

for cmd in curl kubectl; do
    command -v "$cmd" >/dev/null || {
        echo "error: required command not found: $cmd" >&2
        exit 1
    }
done

[[ -f "$KUBECONFIG_FILE" ]] || {
    echo "error: kubeconfig not found: $KUBECONFIG_FILE" >&2
    exit 1
}
export KUBECONFIG="$KUBECONFIG_FILE"

"$SCRIPT_DIR/preflight.sh"

echo "Applying Rook $ROOK_VERSION crds.yaml..."
kubectl apply -f "$ROOK_BASE_URL/crds.yaml"
kubectl wait --for=condition=Established crd/cephclusters.ceph.rook.io --timeout=2m

echo "Applying Rook $ROOK_VERSION common.yaml..."
kubectl apply -f "$ROOK_BASE_URL/common.yaml"

echo "Applying Rook $ROOK_VERSION csi-operator.yaml..."
kubectl apply -f "$ROOK_BASE_URL/csi-operator.yaml"
kubectl wait --for=condition=Established crd/drivers.csi.ceph.io --timeout=2m
kubectl wait --for=condition=Established crd/operatorconfigs.csi.ceph.io --timeout=2m

echo "Applying Rook $ROOK_VERSION operator.yaml..."
kubectl apply -f "$ROOK_BASE_URL/operator.yaml"

kubectl -n "$ROOK_NAMESPACE" rollout status deployment/rook-ceph-operator --timeout=10m

echo "Creating the Ceph cluster from $SCRIPT_DIR/cluster.yaml..."
kubectl apply -f "$SCRIPT_DIR/cluster.yaml"
kubectl -n "$ROOK_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Ready cephcluster/rook-ceph --timeout=20m

echo "Creating the RBD pool and StorageClass..."
kubectl apply -f "$SCRIPT_DIR/rbd-storageclass.yaml"
kubectl -n "$ROOK_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Ready cephblockpool/rook-ceph-rbd-pool --timeout=10m

# Ceph-CSI is managed by the CSI operator. Wait for the RBD driver to register
# before reporting that the StorageClass is ready to use.
for _ in {1..120}; do
    if kubectl get csidriver rook-ceph.rbd.csi.ceph.com >/dev/null 2>&1; then
        kubectl get storageclass rook-ceph-rbd
        echo "Rook/Ceph RBD is ready. Run: task rook-ceph-test"
        exit 0
    fi
    sleep 5
done

echo "error: RBD CSI driver did not register within 10 minutes" >&2
kubectl -n "$ROOK_NAMESPACE" get pods >&2 || true
exit 1
