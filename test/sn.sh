#!/usr/bin/env bash
# Repeatedly enable / disable the Harvester storage-network setting and verify convergence.
#
# Prereqs (doc): all VMs stopped, no pods using Longhorn volumes, no image upload/download,
#                whereabouts CRD installed. Applying the setting stops Longhorn-related pods,
#                Prometheus/Grafana/Alertmanager and vm-import-controller.
#
# Defaults match lab-43 (cluster network snt, VLAN 100). Original value is restored on PASS.
# Usage: ./sn.sh            (override with CLUSTER_NETWORK= VLAN= RANGE= EXCLUDE= ROUNDS=)
set -euo pipefail

CLUSTER_NETWORK=${CLUSTER_NETWORK:-snt}
VLAN=${VLAN:-100}
RANGE=${RANGE:-10.0.20.0/24}
EXCLUDE=${EXCLUDE:-} # comma separated, e.g. 192.168.100.1/32,192.168.100.2/32
ROUNDS=${ROUNDS:-3}
TIMEOUT=${TIMEOUT:-900}
SETTLE=${SETTLE:-20}
SETTING=storage-network
LOG=${LOG:-storage-network-$(date +%Y%m%d-%H%M%S).log}
LH_NS=longhorn-system

log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG" >&2; } # stderr: apply() output is captured
fail() {
  log "FAIL: $*"
  snapshot
  log "state left as-is for debugging. restore with:"
  log "  kubectl patch settings.harvesterhci.io $SETTING --type=merge -p '$(patch_json "${ORIG:-}")'"
  exit 1
}

build_value() {
  local excl="" vlan=""
  [[ -n $EXCLUDE ]] && excl=$(printf '"%s",' ${EXCLUDE//,/ }) && excl="[${excl%,}]"
  [[ -n $VLAN ]] && vlan="\"vlan\":$VLAN,"
  printf '{%s"clusterNetwork":"%s","range":"%s"%s}' \
    "$vlan" "$CLUSTER_NETWORK" "$RANGE" "${excl:+,\"exclude\":$excl}"
}

snapshot() {
  {
    echo "=== snapshot $(date +%T) ==="
    kubectl get settings.harvesterhci.io $SETTING -o yaml
    kubectl -n $LH_NS get settings.longhorn.io storage-network -o jsonpath='{.value}{"\n"}'
    kubectl -n $LH_NS get pods -l longhorn.io/component=instance-manager -o wide
    kubectl -n $LH_NS get pods -l longhorn.io/component=backing-image-manager -o wide
    kubectl -n $LH_NS get pods -l longhorn.io/component=instance-manager \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}{"\n"}{end}'
    kubectl get events -A --field-selector reason=FailedCreatePodSandBox --sort-by=.lastTimestamp | tail -20
    kubectl get pvc -A --no-headers | awk '$3!="Bound"'
  } >>"$LOG" 2>&1
}

preflight() {
  kubectl get crd ippools.whereabouts.cni.cncf.io >/dev/null 2>&1 || fail "whereabouts CRD missing"
  [[ -z $(kubectl get vmi -A --no-headers 2>/dev/null) ]] || fail "VMIs still running; stop all VMs first"
  kubectl get clusternetworks.network.harvesterhci.io "$CLUSTER_NETWORK" >/dev/null 2>&1 ||
    fail "cluster network '$CLUSTER_NETWORK' not found"
}

# IPs on interface $1 for pods matching selector $2, one per line: "<pod> <ip|NONE>"
iface_ips() {
  kubectl -n $LH_NS get pods -l "$2" -o json | python3 -c '
import json,sys
iface=sys.argv[1]
for p in json.load(sys.stdin)["items"]:
    ns=p["metadata"].get("annotations",{}).get("k8s.v1.cni.cncf.io/network-status","[]")
    ips=[ip for n in json.loads(ns) if n.get("interface")==iface for ip in n.get("ips",[])]
    print(p["metadata"]["name"], ips[0] if ips else "NONE")' "$1"
}

in_range() { python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 1)' "$1" "$2"; }

setting_configured_since() {
  local since=$1 st ts
  st=$(kubectl get settings.harvesterhci.io $SETTING -o jsonpath='{.status.conditions[?(@.type=="configured")].status}')
  ts=$(kubectl get settings.harvesterhci.io $SETTING -o jsonpath='{.status.conditions[?(@.type=="configured")].lastUpdateTime}')
  # status True is required; lastUpdateTime is only logged (it may not move if the condition stays True)
  [[ $st == True ]] || return 1
  [[ ! $ts < $since ]] || echo "$(date +%T) note: configured lastUpdateTime $ts older than apply $since" >>"$LOG"
  return 0
}

pods_ready() {
  local sel=$1 total notready
  total=$(kubectl -n $LH_NS get pods -l "$sel" --no-headers 2>/dev/null | wc -l)
  notready=$(kubectl -n $LH_NS get pods -l "$sel" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' | grep -c false || true)
  [[ $total -gt 0 && $notready -eq 0 ]]
}

check_state() { # $1 = on|off, $2 = apply timestamp
  local want=$1 since=$2 lh ip
  setting_configured_since "$since" || return 1
  lh=$(kubectl -n $LH_NS get settings.longhorn.io storage-network -o jsonpath='{.value}')
  if [[ $want == on ]]; then [[ -n $lh ]] || return 1; else [[ -z $lh ]] || return 1; fi

  pods_ready longhorn.io/component=instance-manager || return 1
  pods_ready longhorn.io/component=backing-image-manager || true # may legitimately be 0 pods

  while read -r _ ip; do
    if [[ $want == on ]]; then
      [[ $ip != NONE ]] && in_range "$ip" "$RANGE" || return 1
    else
      [[ $ip == NONE ]] || return 1
    fi
  done < <(iface_ips lhnet1 longhorn.io/component=instance-manager)

  [[ $(kubectl get pvc -A --no-headers | awk '$3!="Bound"' | wc -l) -eq 0 ]] || return 1
  return 0
}

wait_state() {
  local want=$1 since=$2 start=$SECONDS
  sleep "$SETTLE"
  until check_state "$want" "$since"; do
    if kubectl get events -A --field-selector reason=FailedCreatePodSandBox -o jsonpath='{.items[*].message}' |
      grep -q 'Could not allocate IP'; then
      fail "IP exhaustion in storage network range $RANGE"
    fi
    ((SECONDS - start > TIMEOUT)) && fail "not converged to '$want' within ${TIMEOUT}s"
    sleep 15
  done
  log "converged to '$want' in $((SECONDS - start))s"
}

apply() { # $1 = value ("" = disable); echoes apply timestamp
  local v=$1 ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log "set $SETTING='$v'"
  kubectl patch settings.harvesterhci.io $SETTING --type=merge \
    -p "$(patch_json "$v")" >>"$LOG"
  echo "$ts"
}

patch_json() { python3 -c 'import json,sys; print(json.dumps({"value":sys.argv[1]}))' "$1"; }

ORIG=$(kubectl get settings.harvesterhci.io $SETTING -o jsonpath='{.value}')
echo "$ORIG" >"${LOG%.log}.orig"

restore() {
  if [[ $ORIG == "$(kubectl get settings.harvesterhci.io $SETTING -o jsonpath='{.value}')" ]]; then
    log "original value already in place"
    return
  fi
  local ts
  ts=$(apply "$ORIG")
  if [[ -n $ORIG ]]; then wait_state on "$ts"; else wait_state off "$ts"; fi
  log "restored original value: '${ORIG:-<empty>}'"
}

VALUE=$(build_value)
preflight
log "original: ${ORIG:-<empty>}"
log "baseline; target value: $VALUE"
snapshot
for ((i = 1; i <= ROUNDS; i++)); do
  log "--- round $i/$ROUNDS ---"
  ts=$(apply "$VALUE")
  wait_state on "$ts"
  snapshot
  ts=$(apply "")
  wait_state off "$ts"
  snapshot
done
restore
log "PASS: $ROUNDS rounds of enable/disable"
