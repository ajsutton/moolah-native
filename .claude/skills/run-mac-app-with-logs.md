---
name: run-mac-app-with-logs
description: Use when you need to run the macOS app and capture runtime logs to diagnose issues - CloudKit sync problems, crashes, unexpected behavior, or verifying logging output
---

# Run Mac App with Logs

Build, launch the macOS app, capture OS logs for a specified duration, then return the filtered output.

## Usage

```bash
# 1. Kill any existing instances and ensure temp dir
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
sleep 1
mkdir -p .agent-tmp

# 2. Build the app (uses -derivedDataPath .build)
just build-mac

# 3. Start log streaming BEFORE launching the app
#    IMPORTANT: Start the stream first, wait for it to connect, THEN launch.
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app"' \
  --level debug \
  --style compact \
  --timeout 30s \
  > .agent-tmp/app-logs.txt 2>&1 &
LOG_PID=$!
sleep 2  # Give the stream time to connect

# 4. Launch the already-built app
open .build/Build/Products/Debug/Moolah.app

# 5. Wait for the timeout
wait $LOG_PID 2>/dev/null

# 6. Kill the app
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true

# 7. Read the logs (may be large — use head/grep to filter)
cat .agent-tmp/app-logs.txt

# 8. Clean up when done reviewing
rm .agent-tmp/app-logs.txt
```

## Critical Notes

- **Build path**: `just build-mac` and `just run-mac` both use `-derivedDataPath .build`. The built app is at `.build/Build/Products/Debug/Moolah.app`.
- **Start stream first**: Always start `/usr/bin/log stream` BEFORE `open Moolah.app`, otherwise startup logs are missed.
- **Sleep after stream**: Add `sleep 2` between starting the stream and launching the app to ensure the stream is connected.
- **Use `/usr/bin/log`**: The bare `log` command may conflict with shell builtins. Always use the full path.
- **Log redaction**: OSLog redacts dynamic values by default. To see values in Console/log stream, use `privacy: .public` in the logger call. Standard string interpolation shows as `<private>`.

## Filtering

Common predicates (combine with `&&` or `||`):

| Filter | Predicate |
|--------|-----------|
| By subsystem | `subsystem == "com.moolah.app"` |
| By category | `category == "ProfileIndexSyncEngine"` |
| By message content | `eventMessage CONTAINS "sync"` |
| Combined | `subsystem == "com.moolah.app" && category == "ProfileIndexSyncEngine"` |

## Tips

- Use `--timeout 30s` to auto-stop. Increase for longer flows (e.g., `45s` for sync, `2m` for migration).
- Use `--style compact` for readable output. Use `--style ndjson` for machine-parseable JSON.
- If the log file is very large (>256KB), use `head`, `grep`, or `Read` with `offset`/`limit` to inspect portions.
- To capture logs from a specific flow mid-session, use `--process Moolah` instead of the subsystem predicate.
