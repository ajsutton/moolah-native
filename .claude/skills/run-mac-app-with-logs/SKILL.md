---
name: run-mac-app-with-logs
description: Use when you need to run the macOS app and capture runtime logs to diagnose issues - CloudKit sync problems, crashes, unexpected behavior, or verifying logging output
---

# Run Mac App with Logs

Build, launch the macOS app, and stream OS logs continuously to `.agent-tmp/app-logs.txt`.

## Start the app

```bash
# Default: captures all com.moolah.app logs (run in background)
just run-mac-with-logs &

# Custom predicate — must be a single quoted string
just run-mac-with-logs 'category == "ProfileSyncEngine"' &
```

In non-interactive mode (background), the script polls until the app exits. Kill the app to stop both the app and the log stream.

## Monitor for specific events

Use the Monitor tool to stream matching log lines as they arrive:

```
Monitor(
  description: "Moolah sync performance logs",
  command: "tail -f .agent-tmp/app-logs.txt | grep -E --line-buffered 'PERF|error|Failed'",
  timeout_ms: 300000,
  persistent: false
)
```

## Inspect logs

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

## Stop and clean up

```bash
# Kill the app (log stream stops automatically in non-interactive mode)
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true

# Also kill any orphaned log stream
pkill -f "log stream.*com.moolah.app" 2>/dev/null || true

# Clean up
rm .agent-tmp/app-logs.txt
```

## Notes

- **Log redaction**: OSLog redacts dynamic values by default. Use `privacy: .public` in logger calls to see values. Standard string interpolation shows as `<private>`.
- **Large logs**: If the file is large (>256KB), use `grep` or `Read` with `offset`/`limit`.
- **Predicate quoting**: The predicate is passed as a single argument. Use single quotes around the entire predicate in `just run-mac-with-logs`. Parentheses and complex predicates work inside single quotes.
