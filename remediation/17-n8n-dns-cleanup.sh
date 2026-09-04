#!/usr/bin/env bash
# Item 17 (14b) - remove n8n DNS entries.
#
# n8n was removed in items 14/15 but n8n.i3sec.com.au still resolves to
# the Traefik VIP in both resolvers, so it now returns 404 rather than
# NXDOMAIN. Split out from item 14 because applying this reloads LAN-wide
# DNS, which had to wait for out-of-hours.
set -uo pipefail
D="$HOME/gm-dev/dns-conf"
cd "$D" || { echo "dns-conf missing"; exit 2; }
grep -rq "n8n.i3sec.com.au" . --include="*.server" --include="*.yml" 2>/dev/null || { echo "no n8n DNS entries left"; exit 0; }
[ -n "$(git status --porcelain)" ] && { echo "tree dirty"; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "not on main"; exit 2; }
python3 - <<'PY'
import re,io
for p in ("coredns/fragments/i3sec-hosts.server","pihole/pihole-custom-dns-cm.yml"):
    try: s=open(p).read()
    except FileNotFoundError: continue
    out=[l for l in s.splitlines(True) if "n8n.i3sec.com.au" not in l]
    open(p,'w').write("".join(out))
PY
git add -A
git diff --cached --quiet && { echo "nothing changed"; exit 0; }
git commit -q -m "Remove n8n DNS entries

n8n was removed from the cluster, but both resolvers still pointed
n8n.i3sec.com.au at the Traefik VIP, which answered 404 instead of the
name simply not resolving.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
for i in $(seq 1 30); do
  sudo kubectl get cm pihole-custom-dns -n pihole -o yaml 2>/dev/null | grep -q "n8n.i3sec.com.au" || { echo "n8n DNS entries removed and synced"; exit 0; }
  sleep 10
done
echo "pushed but pihole ConfigMap still lists n8n"; exit 1
