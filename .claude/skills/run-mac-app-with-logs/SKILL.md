---
name: run-mac-app-with-logs
description: Use when running the Moolah macOS app with runtime logs captured — diagnosing CloudKit sync problems, crashes, hangs, unexpected behaviour, reproducing a bug that only shows up via `os_log`, or verifying that a newly added log statement actually emits.
---

# Run Mac App with Logs

Build, launch the macOS app, and stream OS logs continuously to `.agent-tmp/app-logs.txt`.

## Start the app

```bash
# Default: captures all com.moolah.app logs
just run-mac-with-logs

# Custom predicate — must be a single quoted string
just run-mac-with-logs 'category == "ProfileSyncEngine"'
```

In non-interactive mode (agents, background), the script builds, launches, starts the log stream, then **exits immediately** — the app and log stream keep running independently. Do NOT run with `&` or `run_in_background` — just run it directly and it will return.

If the app is already running, the script will exit with an error. Stop the existing instance first (see "Stop and clean up" below).

## Wait for logs to accumulate

After `just run-mac-with-logs` returns, the app is running and logs are streaming. Wait a few seconds for startup logs, then inspect:

```bash
# Quick check that logs are flowing
wc -l .agent-tmp/app-logs.txt
```

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
# Kill the app
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true

# Kill the log stream
pkill -f "log stream.*com.moolah.app" 2>/dev/null || true

# Clean up
rm .agent-tmp/app-logs.txt
```

## Check for crash logs

If the app exits unexpectedly, check for crash reports:

```bash
ls -lt ~/Library/Logs/DiagnosticReports/ | grep -i moolah | head -5
```

Parse a crash log for the faulting thread stack trace:

```bash
python3 -c "
import json
data = open('PATH_TO_IPS_FILE').read()
lines = data.strip().split('\n')
crash = json.loads('\n'.join(lines[1:]))
ft = crash['faultingThread']
thread = crash['threads'][ft]
for f in thread.get('frames', [])[:15]:
    sym = f.get('symbol', '?')
    src = f.get('sourceFile', '')
    line = f.get('sourceLine', '')
    loc = f' {src}:{line}' if src and line else ''
    print(f'  {sym}{loc}')
"
```

## Notes

- **Log redaction**: OSLog redacts dynamic values by default. Use `privacy: .public` in logger calls to see values. Standard string interpolation shows as `<private>`.
- **Large logs**: If the file is large (>256KB), use `grep` or `Read` with `offset`/`limit`.
- **Predicate quoting**: The predicate is passed as a single argument. Use single quotes around the entire predicate in `just run-mac-with-logs`. Parentheses and complex predicates work inside single quotes.
