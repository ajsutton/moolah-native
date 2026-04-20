#!/usr/bin/env bash
# Prepares the build tree for local CloudKit development.
#
# 1. Writes .build/Moolah.entitlements with the full sandbox + CloudKit keys.
# 2. Produces project-entitlements.yml — a copy of project.yml with a
#    Debug-only settings block added to each app target that wires in
#    CODE_SIGN_ENTITLEMENTS and the CLOUDKIT_ENABLED compilation condition.
#
# The Debug-Tests configuration deliberately does NOT get these, so
# `just test` never signs the test host with iCloud entitlements. See
# plans/2026-04-20-strip-icloud-from-tests-design.md.
#
# Prints the path to the temp project file. Caller cleans up.
set -euo pipefail

TEMP_FILE="project-entitlements.yml"
ENTITLEMENTS_FILE=".build/Moolah.entitlements"

mkdir -p "$(dirname "$ENTITLEMENTS_FILE")"
cat > "$ENTITLEMENTS_FILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.rocks.moolah.app.v2</string>
    </array>
</dict>
</plist>
PLIST

OUTFILE="$TEMP_FILE" ENTITLEMENTS_FILE="$ENTITLEMENTS_FILE" python3 << 'PY'
import os

with open("project.yml") as f:
    content = f.read()

entitlements_path = os.environ["ENTITLEMENTS_FILE"]

debug_block = "\n".join([
    "        Debug:",
    f"          CODE_SIGN_ENTITLEMENTS: {entitlements_path}",
    '          SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"',
    "",
])

for target in ("Moolah_iOS", "Moolah_macOS"):
    target_header = f"  {target}:\n    type: application\n"
    target_start = content.find(target_header)
    if target_start == -1:
        raise SystemExit(f"inject-entitlements: could not find target {target}")

    configs_marker = "      configs:\n"
    configs_pos = content.find(configs_marker, target_start)
    if configs_pos == -1:
        raise SystemExit(
            f"inject-entitlements: could not find configs: block for {target}"
        )

    insert_at = configs_pos + len(configs_marker)
    content = content[:insert_at] + debug_block + content[insert_at:]

# Sanity check — both app targets now carry a Debug-scoped entitlement block.
marker = "        Debug:\n          CODE_SIGN_ENTITLEMENTS:"
if content.count(marker) != 2:
    raise SystemExit(
        "inject-entitlements: expected 2 Debug entitlement blocks, "
        f"found {content.count(marker)}"
    )

with open(os.environ["OUTFILE"], "w") as f:
    f.write(content)
PY

echo "$TEMP_FILE"
