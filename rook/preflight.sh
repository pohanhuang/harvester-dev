#!/usr/bin/env bash
set -euo pipefail

# Rook will erase every device named in rook/cluster.yaml. This script does
# only read-only checks and must pass before setup.sh applies any manifests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_FILE="$ROOT_DIR/kubeconfig"
SSH_CONFIG="$ROOT_DIR/state/ssh_config"
DEVICE="/dev/vdb"
NODES=(node1 node2 node3)

for cmd in kubectl ssh; do
    command -v "$cmd" >/dev/null || {
        echo "error: required command not found: $cmd" >&2
        exit 1
    }
done

[[ -f "$KUBECONFIG_FILE" ]] || {
    echo "error: kubeconfig not found: $KUBECONFIG_FILE" >&2
    exit 1
}
[[ -f "$SSH_CONFIG" ]] || {
    echo "error: SSH config not found: $SSH_CONFIG" >&2
    exit 1
}

export KUBECONFIG="$KUBECONFIG_FILE"

for node in "${NODES[@]}"; do
    ready="$(kubectl get node "$node" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    [[ "$ready" == "True" ]] || {
        echo "error: Kubernetes node $node is not Ready" >&2
        exit 1
    }

    device_type="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -F "$SSH_CONFIG" "$node" "sudo lsblk -dnro TYPE $DEVICE")"
    fstype="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -F "$SSH_CONFIG" "$node" "sudo lsblk -dnro FSTYPE $DEVICE")"
    mountpoints="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -F "$SSH_CONFIG" "$node" "sudo lsblk -dnro MOUNTPOINTS $DEVICE")"
    device_entries="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -F "$SSH_CONFIG" "$node" "sudo lsblk -nrpo NAME $DEVICE | wc -l")"
    signatures="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -F "$SSH_CONFIG" "$node" "sudo wipefs --noheadings --output TYPE $DEVICE" || true)"

    [[ "$device_type" == "disk" && "$device_entries" == "1" && -z "$fstype" && -z "$mountpoints" && -z "$signatures" ]] || {
        echo "error: $node:$DEVICE is not a single blank, unmounted disk; refusing to let Rook erase it" >&2
        echo "       type=$device_type entries=$device_entries fstype=${fstype:-none} mountpoints=${mountpoints:-none} signatures=${signatures:-none}" >&2
        exit 1
    }

    echo "$node: $DEVICE is a blank raw disk"
done

echo "Preflight passed. Rook may safely consume only /dev/vdb on node1, node2, and node3."
