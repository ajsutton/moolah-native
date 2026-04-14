#!/usr/bin/env bash
# Creates a temporary project.yml with entitlements in the project directory.
# Prints the path to the temp file. Caller cleans up.
set -euo pipefail

TEMP_FILE="project-entitlements.yml"

OUTFILE="$TEMP_FILE" python3 << 'EOF'
import re, os

with open("project.yml") as f:
    content = f.read()

block = "\n".join([
    "    entitlements:",
    "      path: .build/Moolah.entitlements",
    "      properties:",
    "        com.apple.security.app-sandbox: true",
    "        com.apple.security.network.client: true",
    "        com.apple.developer.icloud-services:",
    "          - CloudKit",
    "        com.apple.developer.icloud-container-identifiers:",
    "          - iCloud.rocks.moolah.app",
])

for target in ["Moolah_iOS", "Moolah_macOS"]:
    pattern = rf"(  {target}:\n    type: application\n    platform: (?:iOS|macOS)\n)"
    content = re.sub(pattern, lambda m: m.group(0) + block + "\n", content)

with open(os.environ["OUTFILE"], "w") as f:
    f.write(content)
EOF

echo "$TEMP_FILE"
