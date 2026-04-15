#!/usr/bin/env bash
# Creates a temporary project.yml with entitlements in the project directory.
# Prints the path to the temp file. Caller cleans up.
set -euo pipefail

TEMP_FILE="project-entitlements.yml"

OUTFILE="$TEMP_FILE" python3 << 'EOF'
import re, os

with open("project.yml") as f:
    content = f.read()

entitlements_block = "\n".join([
    "    entitlements:",
    "      path: .build/Moolah.entitlements",
    "      properties:",
    "        com.apple.security.app-sandbox: true",
    "        com.apple.security.network.client: true",
    "        com.apple.security.files.user-selected.read-write: true",
    "        com.apple.developer.icloud-services:",
    "          - CloudKit",
    "        com.apple.developer.icloud-container-identifiers:",
    "          - iCloud.rocks.moolah.app.v2",
])

for target in ["Moolah_iOS", "Moolah_macOS"]:
    pattern = rf"(  {target}:\n    type: application\n    platform: (?:iOS|macOS)\n)"
    content = re.sub(pattern, lambda m: m.group(0) + entitlements_block + "\n", content)

# Add CLOUDKIT_ENABLED Swift compilation condition so isCloudKitAvailable
# can gate CKContainer usage at compile time (prevents NSException crash
# in builds without CloudKit entitlements).
content = content.replace(
    'SWIFT_TREAT_WARNINGS_AS_ERRORS: YES',
    'SWIFT_TREAT_WARNINGS_AS_ERRORS: YES\n    SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"'
)

with open(os.environ["OUTFILE"], "w") as f:
    f.write(content)
EOF

echo "$TEMP_FILE"
