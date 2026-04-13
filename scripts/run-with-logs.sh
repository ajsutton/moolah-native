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
# The script runs until interrupted (Ctrl-C) or the app exits.

set -euo pipefail

PREDICATE="${1:-subsystem == \"com.moolah.app\"}"
LOG_DIR=".agent-tmp"
LOG_FILE="$LOG_DIR/app-logs.txt"
APP_PATH=".build/Build/Products/Debug/Moolah.app"

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
echo "Press Ctrl-C to stop."

# Wait for the log stream process (keeps script alive until interrupted)
wait "$LOG_PID" 2>/dev/null || true
