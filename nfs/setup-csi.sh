#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/config.yaml"
KUBECONFIG_FILE="$ROOT_DIR/kubeconfig"

RELEASE="csi-driver-nfs"
NAMESPACE="kube-system"
CHART_REPO="csi-driver-nfs"
CHART_URL="https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
CHART_VERSION="v4.10.0"
STORAGE_CLASS="nfs-csi"
NFS_SHARE="/backup_target"

for cmd in docker helm kubectl yq; do
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

PREFIX=$(yq -e '.provider.domain_prefix' "$CONFIG_FILE")
NFS_SERVER=$(yq -e '.networks.mgmt.bridge_ip' "$CONFIG_FILE")
NFS_CONTAINER="${PREFIX}-nfs-server"

if [[ "$(docker inspect -f '{{.State.Running}}' "$NFS_CONTAINER" 2>/dev/null || true)" != "true" ]]; then
    echo "error: NFS server is not running; run: task nfs-up" >&2
    exit 1
fi

kubectl --kubeconfig "$KUBECONFIG_FILE" get nodes >/dev/null

helm repo add --force-update "$CHART_REPO" "$CHART_URL" >/dev/null
helm upgrade --install "$RELEASE" "$CHART_REPO/csi-driver-nfs" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --version "$CHART_VERSION" \
    --wait \
    --timeout 5m

kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status \
    "deployment/csi-nfs-controller" -n "$NAMESPACE" --timeout=5m
kubectl --kubeconfig "$KUBECONFIG_FILE" rollout status \
    "daemonset/csi-nfs-node" -n "$NAMESPACE" --timeout=5m

cat <<EOF | kubectl --kubeconfig "$KUBECONFIG_FILE" apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $STORAGE_CLASS
provisioner: nfs.csi.k8s.io
parameters:
  server: $NFS_SERVER
  share: $NFS_SHARE
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.2
EOF

echo "NFS CSI is ready; StorageClass $STORAGE_CLASS uses $NFS_SERVER:$NFS_SHARE"
