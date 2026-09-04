#!/usr/bin/env bash
# Item 10 - remove syslog-store directories with no PV at all.
#
# Item 07 cleaned up directories whose PVs were Released. These are older:
# the PV objects are gone entirely, left by the retired k8smaster-nfs
# provisioner and by app removals that orphaned resources (see the
# resources-finalizer finding in item 15). ~5.1G.
#
# The two largest were verified to be superseded, not live:
#   logging/syslog-storage  -> now longhorn pvc-4989d636
#   postgres/postgres-data  -> now longhorn pvc-b554a843
#
# Guard: refuses if any PV of any phase still references the path, so a
# directory that is actually in use can never be caught by this.
set -uo pipefail
GUARD="/srv/nfs/syslog-store"
STAMP="$(date +%F-%H%M)"
MANIFEST="$(dirname "${BASH_SOURCE[0]}")/state/10-residue-$STAMP.manifest"

mapfile -t INUSE < <(sudo kubectl get pv -o json 2>/dev/null | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    n=p['spec'].get('nfs')
    if n: print(n['path'])
")
mapfile -t DIRS < <(sudo find "$GUARD" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
[ "${#DIRS[@]}" -eq 0 ] && { echo "no residue directories"; exit 0; }

echo "# syslog-store residue removal $STAMP" > "$MANIFEST"
TARGETS=()
for d in "${DIRS[@]}"; do
    skip=0
    for u in "${INUSE[@]}"; do [ "$u" = "$d" ] && skip=1 && break; done
    [ $skip -eq 1 ] && { detail "in use, skipping: $d"; continue; }
    case "$d" in "$GUARD"/?*) ;; *) echo "refusing: $d outside $GUARD"; exit 2;; esac
    printf '%s\t%s\n' "$(sudo du -sh "$d" 2>/dev/null | cut -f1)" "$d" >> "$MANIFEST"
    TARGETS+=("$d")
done
[ "${#TARGETS[@]}" -eq 0 ] && { echo "nothing to remove - all dirs still referenced"; exit 0; }
detail "$(cat "$MANIFEST")"
for d in "${TARGETS[@]}"; do
    sudo rm -rf -- "$d" || { echo "failed removing $d"; exit 1; }
done
echo "removed ${#TARGETS[@]} residue dirs; $GUARD now $(sudo du -sh "$GUARD" 2>/dev/null | cut -f1); manifest $(basename "$MANIFEST")"
exit 0
