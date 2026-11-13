#!/bin/bash
KC="kubectl --kubeconfig /home/po/harvester/harvester-dev/kubeconfig"

UPGRADE=$($KC get upgrade -n harvester-system -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
if [ -z "$UPGRADE" ]; then
  echo "No upgrade found"
  exit 0
fi

$KC get upgrade "$UPGRADE" -n harvester-system -o json | python3 -c "
import json,sys
u=json.load(sys.stdin)
print('Upgrade: ', u['metadata']['name'])
print('Age:     ', u['metadata']['creationTimestamp'])
print('State:   ', u['metadata']['labels'].get('harvesterhci.io/upgradeState',''))
print()
nodes = u['status'].get('nodeStatuses', {})
if nodes:
    print('Nodes:')
    for n,v in nodes.items():
        print(f'  {n}: {v[\"state\"]}')
    print()
print('Conditions:')
for c in u['status'].get('conditions',[]):
    msg = f'  -> {c[\"message\"]}' if c.get('message') else ''
    print(f'  {c[\"type\"]:30s} {c[\"status\"]}{msg}')
"

echo
echo "--- Active Jobs ---"
$KC get jobs -n harvester-system \
  --selector="harvesterhci.io/upgrade=$UPGRADE" \
  --field-selector=status.active=1 2>/dev/null || \
$KC get jobs -n harvester-system \
  --selector="harvesterhci.io/upgrade=$UPGRADE" \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[0].type,ACTIVE:.status.active,SUCCEEDED:.status.succeeded,AGE:.metadata.creationTimestamp" 2>/dev/null
