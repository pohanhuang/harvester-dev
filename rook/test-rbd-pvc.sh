#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_FILE="$ROOT_DIR/kubeconfig"
MANIFEST="$SCRIPT_DIR/test-rbd-pvc.yaml"
TEST_NAME="rook-ceph-rbd-test"
TEST_VALUE="rook-ceph-rbd-$(date +%s)"

command -v kubectl >/dev/null || {
    echo "error: required command not found: kubectl" >&2
    exit 1
}
[[ -f "$KUBECONFIG_FILE" ]] || {
    echo "error: kubeconfig not found: $KUBECONFIG_FILE" >&2
    exit 1
}
export KUBECONFIG="$KUBECONFIG_FILE"

kubectl get storageclass rook-ceph-rbd >/dev/null
kubectl get csidriver rook-ceph.rbd.csi.ceph.com >/dev/null

cleanup() {
    kubectl delete -f "$MANIFEST" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
kubectl apply -f "$MANIFEST"
kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/$TEST_NAME" --timeout=5m
kubectl wait --for=condition=Ready "pod/$TEST_NAME" --timeout=5m

kubectl exec "$TEST_NAME" -- sh -c "printf '%s\n' '$TEST_VALUE' > /data/verify"
[[ "$(kubectl exec "$TEST_NAME" -- cat /data/verify)" == "$TEST_VALUE" ]] || {
    echo "error: read/write verification failed" >&2
    exit 1
}

echo "Rook/Ceph RBD PVC mount and read/write test passed"
