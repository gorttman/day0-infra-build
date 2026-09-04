#!/usr/bin/env bash
# Runs the lowest-numbered remediation script that hasn't completed yet,
# then stops. One item per invocation - safe to drive from cron overnight.
#
# Exit codes a task may return:
#   0  done       - verified, marker written, won't run again
#   1  failed     - nothing changed, safe to retry on the next run
#   2  needs-human- blocked on something a script must not decide alone
#
# Only code 0 writes a .done marker, so 1 and 2 retry next time.
set -uo pipefail

REM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REM_DIR/lib.sh"
# Task scripts run as separate bash processes, so the helper has to be
# exported into their environment - sourcing lib.sh here is not enough.
export -f detail

NEXT=""
for f in "$REM_DIR"/[0-9][0-9]-*.sh; do
    [ -e "$f" ] || continue
    num="$(basename "$f" | cut -d- -f1)"
    [ -f "$STATE_DIR/$num.done" ] && continue
    NEXT="$f"; break
done

if [ -z "$NEXT" ]; then
    echo "queue empty - nothing left to run"
    exit 0
fi

name="$(basename "$NEXT" .sh)"
num="$(basename "$NEXT" | cut -d- -f1)"
export DETAIL="$STATE_DIR/$num.detail.log"
: > "$DETAIL"

out="$(bash "$NEXT" 2>&1)"; rc=$?

case $rc in
    0) log_line "$name" "DONE"        "$out"; touch "$STATE_DIR/$num.done" ;;
    2) log_line "$name" "NEEDS-HUMAN" "$out" ;;
    *) log_line "$name" "FAILED"      "$out" ;;
esac

tail -1 "$LOG"
exit $rc
