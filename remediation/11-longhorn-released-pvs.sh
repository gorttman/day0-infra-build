#!/usr/bin/env bash
# Item 11 - remove Released Longhorn PVs and their volumes.
#
# n8n-data (orphaned by item 15) and jellyfin-cache. Both are
# persistentVolumeReclaimPolicy: Retain, so neither the PV nor the
# underlying Longhorn volume goes away on its own.
#
# Only touches PVs in Released phase with no bound claim.
set -uo pipefail
mapfile -t PVS < <(sudo kubectl get pv -o json 2>/dev/null | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    if p['status']['phase']!='Released': continue
    if p['spec'].get('storageClassName')!='longhorn': continue
    print(p['metadata']['name'])
")
[ "${#PVS[@]}" -eq 0 ] && { echo "no Released Longhorn PVs"; exit 0; }
n=0
for pv in "${PVS[@]}"; do
    phase="$(sudo kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [ "$phase" = "Released" ] || { echo "$pv no longer Released ($phase) - refusing"; exit 2; }
    detail "deleting PV $pv and longhorn volume $pv"
    sudo kubectl delete pv "$pv" --wait=false >>"$DETAIL" 2>&1 || { echo "PV delete failed: $pv"; exit 1; }
    sudo kubectl delete volumes.longhorn.io "$pv" -n longhorn-system --ignore-not-found --wait=false >>"$DETAIL" 2>&1
    n=$((n+1))
done
sleep 10
left="$(sudo kubectl get pv -o json 2>/dev/null | python3 -c "
import json,sys
print(sum(1 for p in json.load(sys.stdin)['items']
          if p['status']['phase']=='Released' and p['spec'].get('storageClassName')=='longhorn'))
")"
[ "$left" = "0" ] && { echo "removed $n Released Longhorn PVs"; exit 0; }
echo "removed $n but $left remain"; exit 1
