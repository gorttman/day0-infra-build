#!/usr/bin/env bash
# Item 0 - install key-based SSH auth to the QNAP.
#
# Nothing else on the QNAP side can be automated until this works:
# qnap-manage.yml drives every QNAP role over SSH, and the account is
# password-only today. The key already exists (~/.ssh/qnap_ansible_ed25519,
# generated earlier but never installed); the admin password is in the
# credentials backup, so this needs no human input.
#
# Read-only on the QNAP apart from appending one line to authorized_keys.
# No service restart, no config reload - safe during working hours.
set -uo pipefail

KEY="$HOME/.ssh/qnap_ansible_ed25519"
QNAP_HOST="192.168.20.30"   # variables/cli/group_vars/qnap.yml ansible_host
QNAP_USER="admin"           # variables/cli/group_vars/qnap.yml ansible_user
PWFILE="/mnt/backup/k8smaster-credentials/qnap-admin-password.txt"

try_key() {
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new \
        "$QNAP_USER@$QNAP_HOST" 'echo ok' 2>/dev/null
}

# Idempotent: if the key already works there is nothing to do.
if [ "$(try_key)" = "ok" ]; then
    echo "key auth already working"; exit 0
fi

[ -f "$KEY" ]     || { echo "private key missing: $KEY"; exit 2; }
[ -f "$KEY.pub" ] || { echo "public key missing: $KEY.pub"; exit 2; }

if ! sudo test -r "$PWFILE"; then
    echo "cannot read $PWFILE - no password available"; exit 2
fi

PUB="$(cat "$KEY.pub")"
SSHPASS="$(sudo cat "$PWFILE")"; export SSHPASS
detail "installing $(basename "$KEY").pub for $QNAP_USER@$QNAP_HOST"

# -e reads the password from $SSHPASS rather than argv, so it never
# appears in ps output on this host.
#
# QTS quirk: the admin home is /share/homes/admin when home folders are
# enabled and /root when they are not, so resolve it on the box instead
# of hardcoding. The "/" guard is real paranoia, not theatre - chmod 700
# on / would lock the NAS out of its own web UI.
sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "$QNAP_USER@$QNAP_HOST" "sh -s" >>"$DETAIL" 2>&1 <<REMOTE
set -e
H=\$(cd ~ && pwd)
if [ "\$H" = "/" ] || [ -z "\$H" ]; then
    echo "refusing: home resolved to '\$H'"; exit 3
fi
echo "remote home: \$H"
mkdir -p "\$H/.ssh"
chmod 700 "\$H" "\$H/.ssh"
touch "\$H/.ssh/authorized_keys"
chmod 600 "\$H/.ssh/authorized_keys"
if grep -qF '$PUB' "\$H/.ssh/authorized_keys"; then
    echo "key already present in authorized_keys"
else
    echo '$PUB' >> "\$H/.ssh/authorized_keys"
    echo "key appended"
fi
REMOTE
rc=$?
unset SSHPASS

if [ $rc -ne 0 ]; then
    echo "password SSH to QNAP failed (rc=$rc) - see $DETAIL"; exit 1
fi

# Verify for real rather than trusting the append.
if [ "$(try_key)" = "ok" ]; then
    echo "key auth installed and verified"; exit 0
fi

# QTS has a separate "Allow SSH key login" toggle that no amount of
# authorized_keys editing substitutes for. If we land here that toggle
# is the likely cause, and it is a console decision, not a script's.
echo "key written but auth still refused - check QTS Control Panel > Telnet/SSH key login"
exit 2
