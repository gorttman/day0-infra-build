#!/usr/bin/env bash
# Item 7 - remove orphaned Released PVs and their backing directories.
#
# 15 PVs from the retired k8smaster-nfs dynamic provisioner sit in
# Released phase (kavita, plus superseded pihole/obsidian/paperless/
# calibre-web/vscode-server claims). Their data still occupies
# /srv/nfs/syslog-store/.
#
# This deletes data, so it is deliberately paranoid:
#   - only PVs actually in Released phase
#   - only paths under /srv/nfs/syslog-store/, never the root itself
#   - every target cross-checked against the paths of NON-Released PVs,
#     because that directory also holds live data for Bound PVs
#   - full inventory written to a dated manifest BEFORE anything is
#     removed, so there is a permanent record of what went
#
# No workload restarts, no network change - safe during working hours.
set -uo pipefail

GUARD="/srv/nfs/syslog-store"
STAMP="$(date +%F-%H%M)"
MANIFEST="$(dirname "${BASH_SOURCE[0]}")/state/07-deleted-$STAMP.manifest"

# Released NFS PVs: name<TAB>path
mapfile -t TARGETS < <(sudo kubectl get pv -o json 2>/dev/null | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    if p['status']['phase'] != 'Released': continue
    nfs = p['spec'].get('nfs')
    if not nfs: continue
    c = p['spec'].get('claimRef', {})
    print('\t'.join([p['metadata']['name'], nfs['path'],
                     c.get('namespace','-'), c.get('name','-')]))
")

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "no Released PVs - nothing to clean"; exit 0
fi

# Paths belonging to PVs that are NOT Released. Any collision means the
# provisioner reused a directory and deleting it would destroy live data.
mapfile -t KEEP < <(sudo kubectl get pv -o json 2>/dev/null | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    if p['status']['phase'] == 'Released': continue
    nfs = p['spec'].get('nfs')
    if nfs: print(nfs['path'])
")

echo "# orphan PV cleanup $STAMP" > "$MANIFEST"
for row in "${TARGETS[@]}"; do
    IFS=$'\t' read -r pv path ns claim <<< "$row"

    case "$path" in
        "$GUARD"/?*) : ;;
        *) echo "refusing: $pv path outside $GUARD -> $path"; exit 2 ;;
    esac
    if [[ "$path" == *".."* ]]; then
        echo "refusing: $pv path contains .. -> $path"; exit 2
    fi
    for k in "${KEEP[@]}"; do
        if [ "$k" = "$path" ]; then
            echo "refusing: $pv path also used by a live PV -> $path"; exit 2
        fi
    done

    size="$(sudo du -sh "$path" 2>/dev/null | cut -f1)"
    [ -z "$size" ] && size="absent"
    printf '%s\t%s\t%s/%s\t%s\n' "$pv" "$path" "$ns" "$claim" "$size" >> "$MANIFEST"
done

detail "manifest: $MANIFEST"
detail "$(cat "$MANIFEST")"

# Everything validated and recorded - now act.
removed=0
for row in "${TARGETS[@]}"; do
    IFS=$'\t' read -r pv path ns claim <<< "$row"
    if [ -d "$path" ]; then
        sudo rm -rf -- "$path" || { echo "failed removing $path"; exit 1; }
    fi
    sudo kubectl delete pv "$pv" --wait=false >>"$DETAIL" 2>&1 \
        || { echo "failed deleting PV $pv"; exit 1; }
    removed=$((removed+1))
done

sleep 5
# Count only Released *NFS* PVs - this script's scope. Released volumes
# on other storage classes (Longhorn) are a different problem and must
# not make this one look like it failed.
left="$(sudo kubectl get pv -o json 2>/dev/null | python3 -c "
import json,sys
print(sum(1 for p in json.load(sys.stdin)['items']
          if p['status']['phase']=='Released' and p['spec'].get('nfs')))
")"
freed="$(sudo du -sh "$GUARD" 2>/dev/null | cut -f1)"

if [ "$left" -eq 0 ]; then
    echo "removed $removed orphan PVs, $GUARD now $freed, manifest $(basename "$MANIFEST")"
    exit 0
fi
echo "removed $removed but $left Released PVs remain - see $DETAIL"
exit 1
