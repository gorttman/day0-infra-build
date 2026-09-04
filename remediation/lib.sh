#!/usr/bin/env bash
# Shared helpers for remediation scripts.
# Sourced by run-next.sh, not executed directly.

REM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$REM_DIR/state"
LOG="$REM_DIR/remediation.log"

mkdir -p "$STATE_DIR"

# One line per run. Deliberately terse - this file is meant to be read
# with `tail`, not paged through.
log_line() {
    printf '%s  %-34s  %-11s  %s\n' \
        "$(date +%F\ %H:%M)" "$1" "$2" "$3" >> "$LOG"
}

# Detail goes to a per-item file so the main log stays one line per run.
detail() { echo "$@" >> "$DETAIL"; }
