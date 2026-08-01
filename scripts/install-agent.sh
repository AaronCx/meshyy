#!/usr/bin/env bash
# meshyy — install meshyyd as a per-user launchd agent.
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# Usage: scripts/install-agent.sh [--release] [--uninstall]
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.aaroncx.meshyyd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.meshyy"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled $LABEL"
    exit 0
fi

CONFIG=debug
[[ "${1:-}" == "--release" ]] && CONFIG=release

BINARY="$PWD/.build/$CONFIG/meshyyd"
if [[ ! -x "$BINARY" ]]; then
    echo "error: $BINARY not found. Run: make build" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
chmod 700 "$LOG_DIR"

sed -e "s|__BINARY__|$BINARY|g" -e "s|__LOG_DIR__|$LOG_DIR|g" \
    launchd/$LABEL.plist > "$PLIST"

# bootout first so a re-install replaces rather than layers. Ignore failure: the
# agent may not be loaded yet.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# bootstrap retries, and they are not optional.
#
# Right after a bootout, launchd can still be tearing the old instance down and
# answers a fresh bootstrap with EIO. Three quick tries is what this used to do,
# and on 2026-08-01 all three lost — leaving the daemon DOWN and every session
# with it, which is the one outcome this script must never produce silently. So:
# more attempts, growing waits, and a verified result rather than a hopeful one.
attempt=1
until launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; do
    if [[ $attempt -ge 8 ]]; then
        echo "error: launchctl bootstrap failed $attempt times; the agent is NOT running" >&2
        echo "       try: launchctl bootstrap gui/$(id -u) $PLIST" >&2
        exit 1
    fi
    echo "bootstrap attempt $attempt failed (launchd is still releasing the old instance); retrying..." >&2
    sleep "$attempt"
    attempt=$((attempt + 1))
done

# CONFIRM it is actually serving, rather than trusting the bootstrap's exit code.
# The socket appears a moment after the process does, so this polls for the thing
# that matters: an answer.
ready=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if "$BINARY" list >/dev/null 2>&1; then ready=true; break; fi
    sleep 1
done
if [[ "$ready" != true ]]; then
    echo "error: the agent was bootstrapped but is not answering on its socket" >&2
    echo "       check: $LOG_DIR/meshyyd.err" >&2
    exit 1
fi

echo "installed $LABEL -> $BINARY"
echo "socket: $HOME/.meshyy/meshyyd.sock"
echo "logs:   $LOG_DIR/meshyyd.log"
echo
echo "attach with: $PWD/.build/$CONFIG/meshyyd attach --session default"
