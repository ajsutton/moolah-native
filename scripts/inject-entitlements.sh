#!/usr/bin/env bash
# Prepares the build tree for local CloudKit development.
#
# 1. Writes .build/Moolah.entitlements with the full sandbox + CloudKit keys.
# 2. Produces project-entitlements.yml — a copy of project.yml that:
#    - Adds a Debug-only block to each app target wiring in
#      CODE_SIGN_ENTITLEMENTS and the CLOUDKIT_ENABLED compilation condition.
#    - Appends CODE_SIGN_ENTITLEMENTS to each target's existing Release block.
#      Release already bakes in CLOUDKIT_ENABLED via project.yml; without the
#      matching entitlements file the signed binary calls CKContainer.default()
#      without the required capability and is killed silently by the hardened
#      runtime at launch — which is what breaks `just install-mac`.
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

release_entitlements_line = (
    f"          CODE_SIGN_ENTITLEMENTS: {entitlements_path}\n"
)

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

    # Append CODE_SIGN_ENTITLEMENTS to this target's existing Release: block.
    # Search forward from the Debug block we just inserted so we stay inside
    # this target's configs: section.
    release_header = "        Release:\n"
    release_pos = content.find(release_header, insert_at)
    if release_pos == -1:
        raise SystemExit(
            f"inject-entitlements: could not find Release: block for {target}"
        )
    release_insert_at = release_pos + len(release_header)
    content = (
        content[:release_insert_at]
        + release_entitlements_line
        + content[release_insert_at:]
    )

# Sanity check — both app targets now carry a Debug-scoped entitlement block
# and a CODE_SIGN_ENTITLEMENTS line at the top of their Release block.
debug_marker = "        Debug:\n          CODE_SIGN_ENTITLEMENTS:"
if content.count(debug_marker) != 2:
    raise SystemExit(
        "inject-entitlements: expected 2 Debug entitlement blocks, "
        f"found {content.count(debug_marker)}"
    )
release_marker = "        Release:\n          CODE_SIGN_ENTITLEMENTS:"
if content.count(release_marker) != 2:
    raise SystemExit(
        "inject-entitlements: expected 2 Release entitlement lines, "
        f"found {content.count(release_marker)}"
    )

with open(os.environ["OUTFILE"], "w") as f:
    f.write(content)
PY

echo "$TEMP_FILE"
