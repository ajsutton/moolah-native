---
name: run-mac-app-with-logs
description: Use when you need to run the macOS app and capture runtime logs to diagnose issues - CloudKit sync problems, crashes, unexpected behavior, or verifying logging output
---

# Run Mac App with Logs

Build, launch the macOS app, and stream OS logs continuously to a file that you can grep/tail as needed.

## Usage

```bash
# 1. Kill any existing instances and ensure temp dir
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
sleep 1
mkdir -p .agent-tmp

# 2. Build the app (uses -derivedDataPath .build)
just build-mac

# 3. Start CONTINUOUS log streaming to a file (no timeout)
#    IMPORTANT: Start the stream first, wait for it to connect, THEN launch.
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app"' \
  --level debug \
  --style compact \
  > .agent-tmp/app-logs.txt 2>&1 &
LOG_PID=$!
sleep 1  # Give the stream time to connect

# 4. Launch the already-built app
open .build/Build/Products/Debug/Moolah.app

# 5. Grep/tail the log file as needed — don't wait for it to finish
grep -i "error\|sync\|failed" .agent-tmp/app-logs.txt
tail -20 .agent-tmp/app-logs.txt

# 6. When done debugging, kill the stream and the app
kill $LOG_PID 2>/dev/null
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true

# 7. Clean up
rm .agent-tmp/app-logs.txt
```

## Critical Notes

- **No timeouts**: Do NOT use `--timeout`. Stream continuously to a file and grep it as needed. Timeouts cut off log capture at arbitrary points and miss important events.
- **Build path**: `just build-mac` and `just run-mac` both use `-derivedDataPath .build`. The built app is at `.build/Build/Products/Debug/Moolah.app`.
- **Start stream first**: Always start `/usr/bin/log stream` BEFORE `open Moolah.app`, otherwise startup logs are missed.
- **Use `/usr/bin/log`**: The bare `log` command may conflict with shell builtins. Always use the full path.
- **Log redaction**: OSLog redacts dynamic values by default. To see values in Console/log stream, use `privacy: .public` in the logger call. Standard string interpolation shows as `<private>`.

## Inspecting Logs

```bash
# Check for errors
grep -i "error\|failed" .agent-tmp/app-logs.txt

# Watch specific category
grep "ProfileSyncEngine" .agent-tmp/app-logs.txt | tail -20

# Count occurrences
grep -c "Failed to save" .agent-tmp/app-logs.txt

# Get context around a match
grep -B2 -A5 "zoneNotFound" .agent-tmp/app-logs.txt
```

## Filtering

Common predicates (combine with `&&` or `||`):

| Filter | Predicate |
|--------|-----------|
| By subsystem | `subsystem == "com.moolah.app"` |
| By category | `category == "ProfileIndexSyncEngine"` |
| By message content | `eventMessage CONTAINS "sync"` |
| Combined | `subsystem == "com.moolah.app" && category == "ProfileIndexSyncEngine"` |

## Tips

- If the log file is very large (>256KB), use `grep`, or `Read` with `offset`/`limit` to inspect portions.
- To capture logs from a specific flow mid-session, use `--process Moolah` instead of the subsystem predicate.
- Use `--style compact` for readable output. Use `--style ndjson` for machine-parseable JSON.
