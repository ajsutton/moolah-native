---
name: run-mac-app-with-logs
description: Use when you need to run the macOS app and capture runtime logs to diagnose issues - CloudKit sync problems, crashes, unexpected behavior, or verifying logging output
---

# Run Mac App with Logs

Build, launch the macOS app, and stream OS logs continuously to `.agent-tmp/app-logs.txt`.

## Start the app

```bash
# Default: captures all com.moolah.app logs
just run-mac-with-logs

# Custom predicate (e.g. specific category)
just run-mac-with-logs 'category == "ProfileSyncEngine"'
```

Run this in the background. Logs stream to `.agent-tmp/app-logs.txt` until you kill the process.

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
# Kill the log stream and the app
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true

# Clean up
rm .agent-tmp/app-logs.txt
```

## Notes

- **Log redaction**: OSLog redacts dynamic values by default. Use `privacy: .public` in logger calls to see values. Standard string interpolation shows as `<private>`.
- **Large logs**: If the file is large (>256KB), use `grep` or `Read` with `offset`/`limit`.
- Use `--style ndjson` for machine-parseable JSON (edit the predicate arg or the script).
