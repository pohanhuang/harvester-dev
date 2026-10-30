#!/usr/bin/env bash
# Repeatedly set / clear a Harvester setting and verify the cluster converges each round.
# Default target: longhorn-v2-data-engine-enabled (each change restarts RKE2 on all nodes).
#
# Usage: ROUNDS=3 SETTING=longhorn-v2-data-engine-enabled ./toggle-v2-engine.sh
set -euo pipefail

SETTING=${SETTING:-longhorn-v2-data-engine-enabled}
ROUNDS=${ROUNDS:-3}
TIMEOUT=${TIMEOUT:-900} # seconds per phase
SETTLE=${SETTLE:-60}    # wait for RKE2 restart to actually begin
LOG=${LOG:-toggle-$(date +%Y%m%d-%H%M%S).log}

log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }
fail() {
  log "FAIL: $*"
  snapshot
  exit 1
}

snapshot() {
  {
    echo "=== snapshot $(date +%T) ==="
    kubectl get settings.harvesterhci.io "$SETTING" -o yaml
    kubectl get nodes -o wide
    kubectl get nodes -o custom-columns='NODE:.metadata.name,HP2Mi:.status.allocatable.hugepages-2Mi'
    kubectl -n longhorn-system get settings.longhorn.io v2-data-engine
    kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager -o wide
    kubectl get pvc -A --no-headers | awk '$3!="Bound"'
  } >>"$LOG" 2>&1
}

# want: "true" or "" (cleared = default false)
check_state() {
  local want=$1 lh hp im
  lh=$(kubectl -n longhorn-system get settings.longhorn.io v2-data-engine -o jsonpath='{.value}' 2>/dev/null) || return 1
  [[ $want == true && $lh != true ]] && return 1
  [[ $want != true && $lh == true ]] && return 1

  kubectl wait --for=condition=Ready nodes --all --timeout=5s >/dev/null 2>&1 || return 1

  # hugepages: expect 2Gi on every node when enabled (skip nodes labeled disable-v2)
  if [[ $want == true ]]; then
    hp=$(kubectl get nodes -l 'node.longhorn.io/disable-v2-data-engine!=true' \
      -o jsonpath='{range .items[*]}{.status.allocatable.hugepages-2Mi}{"\n"}{end}' | grep -vc '^2Gi$' || true)
    [[ $hp -eq 0 ]] || return 1
    im=$(kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager,longhorn.io/data-engine=v2 \
      --no-headers 2>/dev/null | grep -vc ' Running ' || true)
    [[ $im -eq 0 ]] || return 1
    [[ $(kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager,longhorn.io/data-engine=v2 --no-headers 2>/dev/null | wc -l) -gt 0 ]] || return 1
  fi

  # existing volumes must stay Bound (the "don't break Longhorn CSI PVCs" invariant)
  [[ $(kubectl get pvc -A --no-headers | awk '$3!="Bound"' | wc -l) -eq 0 ]] || return 1
  return 0
}

wait_state() {
  local want=$1 start=$SECONDS
  sleep "$SETTLE"
  until check_state "$want"; do
    ((SECONDS - start > TIMEOUT)) && fail "not converged to '${want:-cleared}' within ${TIMEOUT}s"
    sleep 15
  done
  log "converged to '${want:-cleared}' in $((SECONDS - start))s"
}

apply() {
  local v=$1
  log "set $SETTING='$v'"
  kubectl patch settings.harvesterhci.io "$SETTING" --type=merge -p "{\"value\":\"$v\"}"
}

log "baseline"
snapshot
for ((i = 1; i <= ROUNDS; i++)); do
  log "--- round $i/$ROUNDS ---"
  apply true
  wait_state true
  snapshot
  apply ""
  wait_state ""
  snapshot
done
apply true
wait_state true
snapshot
log "PASS: $ROUNDS rounds of set/clear + final set"
