#!/usr/bin/env bash
# Build the macOS app, start log streaming, and launch the app.
# Logs are written to .agent-tmp/app-logs.txt for inspection.
#
# Usage:
#   scripts/run-with-logs.sh [predicate]
#
# Examples:
#   scripts/run-with-logs.sh                                    # default: subsystem == "com.moolah.app"
#   scripts/run-with-logs.sh 'category == "ProfileSyncEngine"'  # custom predicate
#
# The script runs until interrupted (Ctrl-C), the app exits, or (in non-interactive
# mode) the app process is killed externally.

set -euo pipefail

PREDICATE="${1:-subsystem == \"com.moolah.app\"}"
LOG_DIR=".agent-tmp"
LOG_FILE="$LOG_DIR/app-logs.txt"
APP_PATH=".build/Build/Products/Debug/Moolah.app"
APP_BINARY="$APP_PATH/Contents/MacOS/Moolah"

cleanup() {
    echo ""
    echo "Shutting down..."
    [ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null || true
    pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
    echo "Logs saved to $LOG_FILE"
}
trap cleanup EXIT

# Kill any existing instances
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
sleep 1

# Ensure log directory
mkdir -p "$LOG_DIR"

# Build
echo "Building macOS app..."
just build-mac

# Start log stream before launching the app so startup logs are captured
echo "Starting log stream (predicate: $PREDICATE)..."
rm -f "$LOG_FILE"
/usr/bin/log stream \
    --predicate "$PREDICATE" \
    --level debug \
    --style compact \
    > "$LOG_FILE" 2>&1 &
LOG_PID=$!
sleep 1

# Launch
echo "Launching app..."
open "$APP_PATH"

echo "App running. Logs streaming to $LOG_FILE"
echo "Log stream PID: $LOG_PID"

if [ -t 0 ]; then
    # Interactive: wait for Ctrl-C
    echo "Press Ctrl-C to stop."
    wait "$LOG_PID" 2>/dev/null || true
else
    # Non-interactive: wait for the app process to appear, then poll until it exits.
    # This keeps the script (and log stream) alive for the app's lifetime.
    echo "Non-interactive mode — waiting for app to exit..."
    # Wait for app to start (up to 10s)
    for i in $(seq 1 20); do
        if pgrep -f "Moolah.app/Contents/MacOS/Moolah" > /dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
    # Poll until app exits (check every 2s)
    while pgrep -f "Moolah.app/Contents/MacOS/Moolah" > /dev/null 2>&1; do
        sleep 2
    done
    echo "App exited."
fi
