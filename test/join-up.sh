#!/usr/bin/env bash
# Regression: join nodes must not boot until node1 has installed and exposed the VIP.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
LOG="$WORK/events"
mkdir -p "$BIN"

cat >"$BIN/yq" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *.provider.domain_prefix*) echo hvst ;;
  *.node_count*) echo "${MOCK_NODE_COUNT:-3}" ;;
  *.node_installed_timeout*) echo 1 ;;
  *.vip*) echo 10.0.10.100 ;;
  *) echo "unexpected yq query: $*" >&2; exit 1 ;;
esac
EOF

cat >"$BIN/virsh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  start)
    echo "start $2" >>"$JOIN_UP_LOG"
    ;;
  domstate)
    case "${MOCK_MODE:-success}:$2" in
      timeout:hvst-node2|timeout:hvst-node3) echo running ;;
      *) echo 'shut off' ;;
    esac
    ;;
  *) echo "unexpected virsh command: $*" >&2; exit 1 ;;
esac
EOF

cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "wait-vip 10.0.10.100" >>"$JOIN_UP_LOG"
exit 0
EOF

cat >"$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$BIN/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == '+%s' ]]; then
  count_file="${JOIN_UP_LOG}.time"
  count=$(cat "$count_file" 2>/dev/null || echo 0)
  count=$((count + 61))
  printf '%s\n' "$count" >"$count_file"
  printf '%s\n' "$count"
else
  /bin/date "$@"
fi
EOF
chmod +x "$BIN"/*

run_join_up() {
  : >"$LOG"
  rm -f "${LOG}.time"
  PATH="$BIN:$PATH" JOIN_UP_LOG="$LOG" "$REPO_ROOT/op/nodes/join-up.sh"
}

# Three nodes: node1 must install, boot from disk and expose the VIP before joiners start.
run_join_up
expected=$'start hvst-node1\nstart hvst-node1\nwait-vip 10.0.10.100\nstart hvst-node2\nstart hvst-node3'
actual=$(head -n 5 "$LOG")
[[ "$actual" == "$expected" ]] || { printf 'unexpected three-node sequence:\n%s\n' "$actual" >&2; exit 1; }

# A single-node cluster must not attempt to start joiners.
MOCK_NODE_COUNT=1 run_join_up
[[ $(grep -Fc 'start hvst-node1' "$LOG") -eq 2 ]]
! grep -q 'hvst-node2\|hvst-node3' "$LOG"

# A join-install timeout names the still-running join domains.
if MOCK_MODE=timeout run_join_up >"$WORK/timeout.out" 2>&1; then
  echo 'expected join batch timeout' >&2
  exit 1
fi
grep -Fq 'hvst-node2' "$WORK/timeout.out"
grep -Fq 'hvst-node3' "$WORK/timeout.out"

# The existing parallel first-boot task remains unchanged for task up.
awk '/^  nodes-first-boot:/{found=1} found{print} /^  nodes-install:/{exit}' "$REPO_ROOT/op/Taskfile.yml" | grep -Fq 'task: nodes-start'
awk '/^  nodes-join-install:/{found=1} found{print} /^  nodes-reinstall:/{exit}' "$REPO_ROOT/op/Taskfile.yml" | grep -Fq 'task: nodes-join-first-boot'

# Root join-up keeps task up intact while substituting only the sequential node installer.
join_up=$(awk '/^  join-up:/{found=1} found{print} /^  rancher-install:/{exit}' "$REPO_ROOT/Taskfile.yml")
grep -Fq 'deps: [admin-up]' <<<"$join_up"
grep -Fq 'task: nfs-up' <<<"$join_up"
grep -Fq 'task: op:nodes-join-install' <<<"$join_up"
grep -Fq 'task: nfs-csi-up' <<<"$join_up"

echo 'join-up test: PASS'
