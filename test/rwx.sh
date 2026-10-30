#!/usr/bin/env bash
# Repeatedly enable / disable the Harvester rwx-network setting and verify convergence.
#
# Modes:
#   dedicated (default): needs CLUSTER_NETWORK + RANGE (+ optional VLAN, EXCLUDE)
#   share:               MODE=share  -> {"share-storage-network":true}; storage-network must already be configured
#
# Prereq (doc): all non-migratable RWX volumes detached.
# Applying the setting restarts all longhorn-csi-plugin pods (disrupts provisioning/attach/detach).
#
# Defaults match lab-43 (cluster network snt, VLAN 100). Original value is restored on PASS.
# Usage:
#   ./rwx.sh                 (override with CLUSTER_NETWORK= VLAN= RANGE= EXCLUDE= ROUNDS=)
#   MODE=share ./rwx.sh
set -euo pipefail

MODE=${MODE:-dedicated}
CLUSTER_NETWORK=${CLUSTER_NETWORK:-snt}
RANGE=${RANGE:-10.0.19.0/24}
VLAN=${VLAN:-100}
EXCLUDE=${EXCLUDE:-}
ROUNDS=${ROUNDS:-3}
TIMEOUT=${TIMEOUT:-600}
SETTLE=${SETTLE:-15}
SETTING=rwx-network
LH_NS=longhorn-system
CSI_SEL=app=longhorn-csi-plugin
LOG=${LOG:-rwx-network-$(date +%Y%m%d-%H%M%S).log}

log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG" >&2; }
fail() {
  log "FAIL: $*"
  snapshot
  log "state left as-is for debugging. restore with:"
  log "  kubectl patch settings.harvesterhci.io $SETTING --type=merge -p '$(patch_json "${ORIG:-}")'"
  exit 1
}

build_value() {
  if [[ $MODE == share ]]; then
    echo '{"share-storage-network":true}'
    return
  fi
  : "${CLUSTER_NETWORK:?dedicated mode needs CLUSTER_NETWORK}" "${RANGE:?dedicated mode needs RANGE}"
  local excl="" vlan=""
  [[ -n $EXCLUDE ]] && excl=$(printf '"%s",' ${EXCLUDE//,/ }) && excl="[${excl%,}]"
  [[ -n $VLAN ]] && vlan="\"vlan\":$VLAN,"
  printf '{"share-storage-network":false,"network":{%s"clusterNetwork":"%s","range":"%s"%s}}' \
    "$vlan" "$CLUSTER_NETWORK" "$RANGE" "${excl:+,\"exclude\":$excl}"
}

snapshot() {
  {
    echo "=== snapshot $(date +%T) ==="
    kubectl get settings.harvesterhci.io $SETTING -o yaml
    kubectl -n $LH_NS get settings.longhorn.io endpoint-network-for-rwx-volume -o jsonpath='{.value}{"\n"}'
    kubectl -n $LH_NS get pods -l $CSI_SEL -o wide
    kubectl -n $LH_NS get pods -l $CSI_SEL \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}{"\n"}{end}'
    kubectl -n $LH_NS get pods -l longhorn.io/component=share-manager -o wide
    kubectl get events -A --field-selector reason=FailedCreatePodSandBox --sort-by=.lastTimestamp | tail -20
    kubectl get pvc -A --no-headers | awk '$3!="Bound"'
  } >>"$LOG" 2>&1
}

preflight() {
  # Same rule as longhorn-manager AreAllRWXVolumesDetached(): a non-migratable RWX volume whose
  # Longhorn VolumeAttachment still has tickets blocks endpoint-network-for-rwx-volume forever
  # (volume state does not matter -- a faulted/attaching volume with a ticket blocks too).
  local blockers
  blockers=$({
    kubectl -n $LH_NS get volumes.longhorn.io -o json
    echo '%%'
    kubectl -n $LH_NS get volumeattachments.longhorn.io -o json
  } | python3 -c '
import json,sys
vols,vas=sys.stdin.read().split("%%")
tickets={v["metadata"]["name"]:v["spec"].get("attachmentTickets") or {} for v in json.loads(vas)["items"]}
for v in json.loads(vols)["items"]:
    s=v["spec"]; st=v.get("status",{})
    if s.get("accessMode")!="rwx" or s.get("migratable"): continue
    t=tickets.get(v["metadata"]["name"])
    if t:
        ks=st.get("kubernetesStatus",{})
        print("%s(pvc=%s/%s state=%s tickets=%s)"%(v["metadata"]["name"],ks.get("namespace"),ks.get("pvcName"),
              st.get("state"),",".join(x.get("type","?")+"@"+x.get("nodeID","?") for x in t.values())))')
  [[ -z $blockers ]] || fail "RWX volumes with attachment tickets block Longhorn from applying: $blockers"
  if [[ $MODE == share ]]; then
    [[ -n $(kubectl -n $LH_NS get settings.longhorn.io storage-network -o jsonpath='{.value}') ]] ||
      fail "share mode requires storage-network to be configured first"
  fi
}

iface_ips() { # $1 iface, $2 selector -> "<pod> <ip|NONE>"
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

REASON=""
check_state() { # $1 on|off, $2 apply timestamp; sets REASON on failure
  local want=$1 since=$2 lh pod ip st
  st=$(kubectl get settings.harvesterhci.io $SETTING \
    -o jsonpath='{range .status.conditions[?(@.type=="configured")]}{.status}/{.reason}/{.message}{end}')
  [[ $st == True/* ]] || {
    REASON="harvester setting configured=$st"
    return 1
  }
  setting_configured_since "$since" || true

  lh=$(kubectl -n $LH_NS get settings.longhorn.io endpoint-network-for-rwx-volume -o jsonpath='{.value}')
  if [[ $want == on ]]; then
    [[ -n $lh ]] || {
      REASON="longhorn endpoint-network-for-rwx-volume still empty"
      return 1
    }
  else
    [[ -z $lh ]] || {
      REASON="longhorn endpoint-network-for-rwx-volume still '$lh'"
      return 1
    }
  fi

  local applied
  applied=$(kubectl -n $LH_NS get settings.longhorn.io endpoint-network-for-rwx-volume -o jsonpath='{.status.applied}')
  [[ $applied == true ]] || {
    REASON="longhorn setting not applied yet (status.applied=$applied; check RWX attachment tickets)"
    return 1
  }

  kubectl -n $LH_NS rollout status ds/longhorn-csi-plugin --timeout=5s >/dev/null 2>&1 || {
    REASON="csi-plugin rollout: $(kubectl -n $LH_NS get ds longhorn-csi-plugin \
      -o jsonpath='desired={.status.desiredNumberScheduled} updated={.status.updatedNumberScheduled} ready={.status.numberReady}')"
    return 1
  }

  while read -r pod ip; do
    if [[ $want == on ]]; then
      [[ $ip != NONE ]] || {
        REASON="$pod has no lhnet2"
        return 1
      }
      if [[ $MODE == dedicated ]]; then
        in_range "$ip" "$RANGE" || {
          REASON="$pod lhnet2 $ip not in $RANGE"
          return 1
        }
      fi
    else
      [[ $ip == NONE ]] || {
        REASON="$pod still has lhnet2 $ip"
        return 1
      }
    fi
  done < <(iface_ips lhnet2 "$CSI_SEL")

  local nb
  nb=$(kubectl get pvc -A --no-headers | awk '$3!="Bound"{print $1"/"$2"="$3}' | tr '\n' ' ')
  [[ -z $nb ]] || {
    REASON="PVC not Bound: $nb"
    return 1
  }
  REASON=""
  return 0
}

wait_state() {
  local want=$1 since=$2 start=$SECONDS
  sleep "$SETTLE"
  local last=""
  until check_state "$want" "$since"; do
    if [[ $REASON != "$last" ]]; then
      log "  waiting ($((SECONDS - start))s): $REASON"
      last=$REASON
    fi
    if kubectl get events -A --field-selector reason=FailedCreatePodSandBox -o jsonpath='{.items[*].message}' |
      grep -q 'Could not allocate IP'; then
      fail "IP exhaustion in RWX network range"
    fi
    ((SECONDS - start > TIMEOUT)) && fail "not converged to '$want' within ${TIMEOUT}s; last blocker: $REASON"
    sleep 10
  done
  log "converged to '$want' in $((SECONDS - start))s"
}

apply() {
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
log "baseline; mode=$MODE value: $VALUE"
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
