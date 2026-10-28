#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_FILE="$ROOT_DIR/kubeconfig"
MANIFEST="$SCRIPT_DIR/test-rwo-pvc.yaml"
TEST_NAME="nfs-csi-rwo-test"
TEST_VALUE="nfs-csi-$(date +%s)"

command -v kubectl >/dev/null || {
    echo "error: required command not found: kubectl" >&2
    exit 1
}

[[ -f "$KUBECONFIG_FILE" ]] || {
    echo "error: kubeconfig not found: $KUBECONFIG_FILE" >&2
    exit 1
}

kubectl --kubeconfig "$KUBECONFIG_FILE" get storageclass nfs-csi >/dev/null

cleanup() {
    kubectl --kubeconfig "$KUBECONFIG_FILE" delete -f "$MANIFEST" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
kubectl --kubeconfig "$KUBECONFIG_FILE" apply -f "$MANIFEST"
kubectl --kubeconfig "$KUBECONFIG_FILE" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$TEST_NAME" --timeout=5m
kubectl --kubeconfig "$KUBECONFIG_FILE" wait --for=condition=Ready "pod/$TEST_NAME" --timeout=5m

kubectl --kubeconfig "$KUBECONFIG_FILE" exec "$TEST_NAME" -- sh -c "printf '%s\n' '$TEST_VALUE' > /data/verify"
[[ "$(kubectl --kubeconfig "$KUBECONFIG_FILE" exec "$TEST_NAME" -- cat /data/verify)" == "$TEST_VALUE" ]] || {
    echo "error: read/write verification failed" >&2
    exit 1
}

echo "NFS CSI RWO mount and read/write test passed"
