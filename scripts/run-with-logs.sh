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
# Interactive mode (terminal):  Runs until Ctrl-C, then stops the app and log stream.
# Non-interactive mode (agent): Builds, launches, starts log stream, then exits.
#   The app and log stream keep running. Clean up with:
#     pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null
#     pkill -f "log stream.*com.moolah.app" 2>/dev/null

set -euo pipefail

PREDICATE="${1:-subsystem == \"com.moolah.app\"}"
# Shift off the predicate so $@ holds any extra launch arguments for
# the app binary (e.g. --ui-testing). `shift` fails on an empty list,
# hence the `|| true` guard for the no-args case.
shift || true
LOG_DIR=".agent-tmp"
LOG_FILE="$LOG_DIR/app-logs.txt"
APP_PATH=".build/Build/Products/Debug/Moolah.app"

# Ensure log directory
mkdir -p "$LOG_DIR"

# Check for existing app instance
if pgrep -f "Moolah.app/Contents/MacOS/Moolah" > /dev/null 2>&1; then
    echo "⚠️  Moolah is already running. Kill it first or use the running instance."
    echo "   pkill -f 'Moolah.app/Contents/MacOS/Moolah'"
    exit 1
fi

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
if [ $# -gt 0 ]; then
    open "$APP_PATH" --args "$@"
else
    open "$APP_PATH"
fi

# Wait for app to appear (up to 10s)
for i in $(seq 1 20); do
    if pgrep -f "Moolah.app/Contents/MacOS/Moolah" > /dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

APP_PID=$(pgrep -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || echo "unknown")
echo "App running (PID: $APP_PID). Logs streaming to $LOG_FILE"
echo "Log stream PID: $LOG_PID"

if [ -t 0 ]; then
    # Interactive: wait for Ctrl-C, then clean up
    cleanup() {
        echo ""
        echo "Shutting down..."
        kill "$LOG_PID" 2>/dev/null || true
        pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
        echo "Logs saved to $LOG_FILE"
    }
    trap cleanup EXIT
    echo "Press Ctrl-C to stop."
    wait "$LOG_PID" 2>/dev/null || true
else
    # Non-interactive (agent): exit and leave app + log stream running.
    echo "Non-interactive mode — app and log stream will keep running."
    echo "To stop later:"
    echo "  pkill -f 'Moolah.app/Contents/MacOS/Moolah'"
    echo "  kill $LOG_PID  # or: pkill -f 'log stream.*com.moolah.app'"
fi
