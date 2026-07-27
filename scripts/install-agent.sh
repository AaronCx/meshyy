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
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "installed $LABEL -> $BINARY"
echo "socket: $HOME/.meshyy/meshyyd.sock"
echo "logs:   $LOG_DIR/meshyyd.log"
echo
echo "attach with: $PWD/.build/$CONFIG/meshyyd attach --session default"
