#!/usr/bin/env bash
# Find an available iPhone simulator, preferring "Pro" (non-Max) models.
# Usage: scripts/find-simulator.sh
# Override with IOS_SIMULATOR env var.
set -euo pipefail

if [[ -n "${IOS_SIMULATOR:-}" ]]; then
    echo "$IOS_SIMULATOR"
    exit 0
fi

xcrun simctl list devices available -j \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' not in runtime and 'iphone' not in runtime.lower():
        continue
    for d in devices:
        name = d.get('name', '')
        if 'iPhone' in name and 'Pro' in name and 'Max' not in name:
            print(name)
            sys.exit(0)
# Fallback: any iPhone
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' not in runtime and 'iphone' not in runtime.lower():
        continue
    for d in devices:
        name = d.get('name', '')
        if 'iPhone' in name:
            print(name)
            sys.exit(0)
print('ERROR: No iPhone simulator found', file=sys.stderr)
sys.exit(1)
"
