#!/usr/bin/env bash
# Build the macOS app, launch it suspended, attach a PID-filtered log
# stream, then resume the app. Logs are written to .agent-tmp/app-logs.txt.
#
# The PID filter ensures the captured logs come ONLY from this launch's
# process — not from concurrent test hosts (MoolahTests_macOS is loaded
# into a Moolah-named binary and emits under the same `com.moolah.app`
# subsystem) or other Moolah instances.
#
# Usage:
#   scripts/run-with-logs.sh [predicate] [launch-args...]
#
# Examples:
#   scripts/run-with-logs.sh                                    # default: subsystem == "com.moolah.app"
#   scripts/run-with-logs.sh 'category == "ProfileSyncEngine"'  # custom predicate
#   scripts/run-with-logs.sh 'subsystem == "com.moolah.app"' --ui-testing
#
# Interactive mode (terminal):  Runs until Ctrl-C, then stops the app and log stream.
# Non-interactive mode (agent): Builds, launches, starts log stream, then exits.
#   The app and log stream keep running. Clean up with:
#     pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null
#     pkill -f "log stream.*processIdentifier" 2>/dev/null

set -euo pipefail

USER_PREDICATE="${1:-subsystem == \"com.moolah.app\"}"
# Shift off the predicate so $@ holds any extra launch arguments for
# the app binary (e.g. --ui-testing). `shift` fails on an empty list,
# hence the `|| true` guard for the no-args case.
shift || true
LOG_DIR=".agent-tmp"
LOG_FILE="$LOG_DIR/app-logs.txt"
APP_PATH=".build/Build/Products/Debug/Moolah.app"
APP_BINARY="$APP_PATH/Contents/MacOS/Moolah"

mkdir -p "$LOG_DIR"

if pgrep -f "Moolah.app/Contents/MacOS/Moolah" > /dev/null 2>&1; then
    echo "⚠️  Moolah is already running. Kill it first or use the running instance."
    echo "   pkill -f 'Moolah.app/Contents/MacOS/Moolah'"
    exit 1
fi

echo "Building macOS app..."
just build-mac

# Launch the binary suspended BEFORE it execs, so we can attach a
# PID-filtered log stream that catches the very first log emitted by
# main(). The wrapper `sh -c` self-sends SIGSTOP (its own `$$` matches
# the parent-visible `$!`), then `exec`s into Moolah once the parent
# SIGCONTs it — `exec` preserves the PID, so the stream subscription
# is already in place when the app starts running.
#
# We use `sh -c` rather than a bash subshell because macOS ships bash
# 3.2 (no `$BASHPID`), so a bash subshell cannot identify itself
# without a child fork. `sh -c` is a fresh process whose `$$` is
# unambiguous and matches `$!` in the parent.
echo "Launching app (suspended)..."
rm -f "$LOG_FILE"
sh -c 'kill -STOP $$; exec "$@"' _ "$APP_BINARY" "$@" </dev/null >/dev/null 2>&1 &
APP_PID=$!

# Resume + clean up if anything below fails before we hand off.
on_error() {
    kill -CONT "$APP_PID" 2>/dev/null || true
    kill "$APP_PID" 2>/dev/null || true
    if [ -n "${LOG_PID:-}" ]; then
        kill "$LOG_PID" 2>/dev/null || true
    fi
}
trap on_error ERR

# Wait until the kernel reports the subshell as stopped (state 'T')
# before subscribing. This avoids a race where the parent could start
# the log stream before the subshell has actually paused.
for _ in $(seq 1 40); do
    if ps -o state= -p "$APP_PID" 2>/dev/null | grep -q '^T'; then
        break
    fi
    sleep 0.05
done

PREDICATE="processIdentifier == $APP_PID AND ($USER_PREDICATE)"
echo "Starting log stream (predicate: $PREDICATE)..."
/usr/bin/log stream \
    --predicate "$PREDICATE" \
    --level debug \
    --style compact \
    > "$LOG_FILE" 2>&1 &
LOG_PID=$!

# Brief settle so `log stream` has subscribed before we resume the app.
sleep 0.5

kill -CONT "$APP_PID"
trap - ERR

echo "App running (PID: $APP_PID). Logs streaming to $LOG_FILE"
echo "Log stream PID: $LOG_PID"

if [ -t 0 ]; then
    cleanup() {
        echo ""
        echo "Shutting down..."
        kill "$LOG_PID" 2>/dev/null || true
        kill "$APP_PID" 2>/dev/null || true
        echo "Logs saved to $LOG_FILE"
    }
    trap cleanup EXIT
    echo "Press Ctrl-C to stop."
    wait "$LOG_PID" 2>/dev/null || true
else
    # Detach so the app and stream survive the parent shell exiting.
    disown "$APP_PID" 2>/dev/null || true
    disown "$LOG_PID" 2>/dev/null || true
    echo "Non-interactive mode — app and log stream will keep running."
    echo "To stop later:"
    echo "  kill $APP_PID  # or: pkill -f 'Moolah.app/Contents/MacOS/Moolah'"
    echo "  kill $LOG_PID  # or: pkill -f 'log stream.*processIdentifier'"
fi
