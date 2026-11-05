#!/usr/bin/env bash
# Install node1 before booting join nodes, which require node1's VIP profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
VIRSH=${VIRSH:-virsh}

CONFIG_FILE=$(get_config_file)
PREFIX=$(yq '.provider.domain_prefix' "$CONFIG_FILE")
NODE_COUNT=$(yq '.node_count' "$CONFIG_FILE")
TIMEOUT_MINUTES=$(yq '.node_installed_timeout // 20' "$CONFIG_FILE")

wait_for_shutdown() {
  local domains=("$@") start now state domain all_shutoff
  start=$(date +%s)

  echo "Waiting for ${domains[*]} to shut off after installation..."
  while true; do
    all_shutoff=true
    for domain in "${domains[@]}"; do
      state=$(domain_state "$domain" || echo "not found")
      if [[ "$state" != "shut off" ]]; then
        echo "Domain $domain is in state: $state"
        all_shutoff=false
      fi
    done
    "$all_shutoff" && return 0

    now=$(date +%s)
    if (( now - start >= TIMEOUT_MINUTES * 60 )); then
      echo "Error: Timeout reached after $TIMEOUT_MINUTES minutes. Not all VMs shut off." >&2
      return 1
    fi
    sleep 30
  done
}

node1="${PREFIX}-node1"
libvirt_start_domain "$node1"
wait_for_shutdown "$node1"

libvirt_start_domain "$node1"
"$SCRIPT_DIR/wait-vip.sh"

if (( NODE_COUNT > 1 )); then
  join_nodes=()
  for i in $(seq 2 "$NODE_COUNT"); do
    node="${PREFIX}-node${i}"
    join_nodes+=("$node")
    libvirt_start_domain "$node"
  done
  wait_for_shutdown "${join_nodes[@]}"
fi
