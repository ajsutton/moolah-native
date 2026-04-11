# iOS Release Automation Plan

**Goal:** Get Moolah running on iOS via TestFlight for personal use, with iCloud sync across devices. Automated monthly builds keep the 90-day TestFlight expiry at bay. Full App Store deployment is a future milestone.

**Current State:**
- GitHub Actions CI runs tests and linting only (`.github/workflows/ci.yml`)
- XcodeGen generates `Moolah.xcodeproj` from `project.yml`
- Code signing is environment-variable driven but not configured for distribution
- No Fastlane, no provisioning profiles, no App Store Connect integration
- Version is hardcoded to `1.0` (build `1`) in `App/Info.plist`
- Bundle ID: `rocks.moolah.app` (shared across iOS and macOS targets)
- Remote backend exists alongside CloudKit — both available for TestFlight; remote will be gated for App Store builds later

---

## Architecture Overview

```
Tag v1.0.0              GitHub Actions              App Store Connect
    │                        │                            │
    ├──► testflight.yml ──► Fastlane ──► TestFlight ──► Install on devices
    │                           │
    │                      match (signing)
    │                      gym (archive)
    │                      pilot (upload)
    │
monthly-tag.yml (cron) ──► creates tag ──► triggers testflight.yml
```

**Key decisions:**
- **Fastlane** for build/sign/upload orchestration (industry standard, well-maintained)
- **Fastlane Match** for code signing (git-encrypted certificate storage)
- **App Store Connect API Key** for authentication (no passwords, no 2FA prompts)
- **Git tags** trigger release builds (e.g., `v1.0.0`, `v1.0.0-monthly.202604`)
- **Build numbers** auto-increment from App Store Connect (latest + 1)
- **Monthly cron job** auto-tags to keep TestFlight builds fresh (90-day expiry)
- **Both backends available** in TestFlight builds (CloudKit + remote server)
- **Remote backend disabled** via `APPSTORE_BUILD` compilation condition — deferred to Milestone 2 (App Store)

---

# Milestone 1: TestFlight for Personal Use

Minimum work to get Moolah installable on iOS via TestFlight with both CloudKit and remote server backends available.

---

## Phase 1: Project Configuration (Code — Do Now)

### 2.1 — Versioning

**File: `project.yml`**

- [x] **Add `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`** to the base settings:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0.0"       # Semantic version (shown to users)
    CURRENT_PROJECT_VERSION: "1"     # Build number (auto-incremented by Fastlane)
```

**File: `App/Info.plist`**

- [x] **Replace hardcoded version strings** with build setting variables:

```xml
<key>CFBundleShortVersionString</key>
<string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key>
<string>$(CURRENT_PROJECT_VERSION)</string>
```

### 2.2 — macOS Hardened Runtime

**File: `project.yml`**

- [x] **Enable hardened runtime for macOS Release builds.** Currently `ENABLE_HARDENED_RUNTIME: NO`. Add a Release configuration override:

```yaml
Moolah_macOS:
  settings:
    base:
      # ...existing settings...
    configs:
      Release:
        ENABLE_HARDENED_RUNTIME: YES
```

Hardened runtime is required for macOS notarization. Not strictly needed for TestFlight-only iOS, but good to have ready.

### 2.3 — Entitlements File

- [x] **Create `App/Moolah.entitlements`** (shared by both iOS and macOS targets):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.rocks.moolah.app</string>
    </array>
</dict>
</plist>
```

### 2.4 — Project Configuration for Entitlements

- [x] **Update `project.yml`** to wire entitlements and iCloud capability to both targets:

```yaml
# In each target's settings:
settings:
  base:
    CODE_SIGN_ENTITLEMENTS: App/Moolah.entitlements

# In each target's attributes (XcodeGen syntax):
attributes:
  SystemCapabilities:
    com.apple.iCloud:
      enabled: 1
```

### 2.5 — SwiftData CloudKit Configuration

- [x] **Update `MoolahApp.init()`** to enable CloudKit sync in the `ModelConfiguration`:

```swift
let config = ModelConfiguration(
    cloudKitDatabase: .automatic  // Syncs via iCloud when signed in, local-only otherwise
)
container = try ModelContainer(for: schema, configurations: [config])
```

Using `.automatic` means the app works offline and without an iCloud account (local storage only), and syncs across devices when signed in to iCloud.

---

## Phase 2: Fastlane & Workflow Files (Config — Do Now)

These files can be written and committed now. They won't run until secrets are configured (Phase 4), but the config is ready.

### 2.1 — Fastlane Setup

- [x] **Add `Gemfile`** to project root:

```ruby
source "https://rubygems.org"

gem "fastlane"
```

- [x] **Add Fastlane environment config.** Create `fastlane/.env` (checked into the repo):

```
FASTLANE_OPT_OUT_USAGE=YES
FASTLANE_SKIP_UPDATE_CHECK=1
```

- [x] **Add to `.gitignore`** (do this BEFORE creating any Fastlane config files):

```
# Fastlane
fastlane/report.xml
fastlane/Preview.html
fastlane/screenshots/**/*.png
fastlane/test_output
fastlane/api_key.json
vendor/bundle
```

### 2.2 — Fastlane Configuration Files

- [x] **Create `fastlane/Appfile`:**

```ruby
app_identifier("rocks.moolah.app")
apple_id(ENV["APPLE_ID"])  # only needed for deliver, not for API key auth
team_id(ENV["DEVELOPMENT_TEAM"])
```

- [x] **Create `fastlane/Matchfile`:**

```ruby
git_url(ENV["MATCH_GIT_URL"])  # e.g., "https://github.com/ajsutton/moolah-certificates.git"

storage_mode("git")

type("appstore")  # default type

app_identifier("rocks.moolah.app")
team_id(ENV["DEVELOPMENT_TEAM"])

# API key is passed directly from env vars in the Fastfile — no local file needed
```

- [x] **`fastlane/api_key.json` (local development only, already gitignored in 2.1):**

  If you need to run Fastlane locally (not in CI), create this file manually. Never commit it.

```json
{
  "key_id": "YOUR_KEY_ID",
  "issuer_id": "YOUR_ISSUER_ID",
  "key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----",
  "in_house": false
}
```

### 2.3 — Fastfile

- [x] **Create `fastlane/Fastfile`:**

```ruby
default_platform(:ios)

before_all do
  # Regenerate Xcode project from project.yml
  sh("cd .. && just generate")
end

platform :ios do
  before_all do
    setup_ci  # Creates a temporary keychain to avoid macOS password prompts
  end

  desc "Sync certificates and profiles for iOS"
  lane :certificates do
    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_CONTENT"],
      is_key_content_base64: true
    )

    match(
      type: "appstore",
      app_identifier: "rocks.moolah.app",
      api_key: api_key,
      readonly: is_ci
    )
  end

  desc "Build and upload iOS app to TestFlight"
  lane :beta do
    certificates

    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_CONTENT"],
      is_key_content_base64: true
    )

    # Auto-increment build number from App Store Connect
    increment_build_number(
      build_number: latest_testflight_build_number(api_key: api_key) + 1
    )

    build_app(
      scheme: "Moolah-iOS",
      export_method: "app-store",
      output_directory: "./build",
      output_name: "Moolah.ipa",
      xcargs: "-allowProvisioningUpdates"
    )

    upload_to_testflight(
      api_key: api_key,
      skip_waiting_for_build_processing: true
    )
  end
end
```

**Note:** The Fastfile builds using the `Moolah-iOS` scheme, which uses the Release configuration by default for archive builds. This means `APPSTORE_BUILD` is automatically active, disabling the remote backend.

### 2.4 — TestFlight Workflow

- [x] **Create `.github/workflows/testflight.yml`:**

```yaml
name: TestFlight

on:
  push:
    tags:
      - "v*"  # Trigger on version tags like v1.0.0, v1.0.0-monthly.202604

permissions:
  contents: read

jobs:
  deploy:
    name: Build & Upload to TestFlight
    runs-on: macos-26
    timeout-minutes: 30
    environment: testflight

    steps:
      - uses: actions/checkout@v6

      - name: Install tools
        run: brew install xcodegen just

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
          bundler-cache: true

      - name: Set version from tag
        run: |
          VERSION=${GITHUB_REF_NAME#v}   # Strip "v" prefix: v1.0.0 → 1.0.0
          echo "APP_VERSION=$VERSION" >> $GITHUB_ENV

      - name: Update marketing version
        run: |
          sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$APP_VERSION\"/" project.yml

      - name: Deploy to TestFlight
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
          MATCH_GIT_URL: ${{ secrets.MATCH_GIT_URL }}
          MATCH_PASSWORD: ${{ secrets.MATCH_PASSWORD }}
          MATCH_GIT_BASIC_AUTHORIZATION: ${{ secrets.MATCH_GIT_BASIC_AUTHORIZATION }}
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CODE_SIGN_STYLE: "Manual"
        run: bundle exec fastlane ios beta

      - name: Upload IPA artifact
        uses: actions/upload-artifact@v4
        with:
          name: Moolah-${{ env.APP_VERSION }}.ipa
          path: build/Moolah.ipa
```

### 2.5 — Monthly Auto-Tag Workflow

- [x] **Create `.github/workflows/monthly-tag.yml`:**

```yaml
name: Monthly TestFlight Tag

on:
  schedule:
    - cron: "0 9 1 * *"  # 9 AM UTC on the 1st of each month
  workflow_dispatch: {}    # Allow manual trigger

permissions:
  contents: write  # Needed to push tags

jobs:
  tag:
    name: Create Monthly Tag
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0  # Need full history for tagging

      - name: Get current version
        id: version
        run: |
          VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
          MONTH=$(date -u +%Y%m)
          TAG="v${VERSION}-monthly.${MONTH}"
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"

      - name: Check if tag exists
        id: check
        run: |
          if git rev-parse "${{ steps.version.outputs.tag }}" >/dev/null 2>&1; then
            echo "exists=true" >> "$GITHUB_OUTPUT"
          else
            echo "exists=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Create and push tag
        if: steps.check.outputs.exists == 'false'
        run: |
          git tag "${{ steps.version.outputs.tag }}"
          git push origin "${{ steps.version.outputs.tag }}"
```

This runs on the 1st of each month. The tag (e.g., `v1.0.0-monthly.202604`) triggers the TestFlight workflow automatically, keeping builds within the 90-day expiry window. Can also be triggered manually via `workflow_dispatch`.

### 2.6 — Justfile Targets

- [x] **Add release-related targets** to `justfile`:

```just
# Sync code signing certificates (runs Match)
certificates:
    bundle exec fastlane ios certificates

# Build and upload to TestFlight
testflight: generate
    bundle exec fastlane ios beta

# Bump marketing version (usage: just bump-version 1.2.0)
bump-version version:
    sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: "{{version}}"/' project.yml
    just generate
```

---

## Phase 3: Apple Developer Account Setup (Manual, One-Time — Requires Enrollment)

These steps must be done in the Apple Developer portal.

- [ ] **3.1 — Enroll in Apple Developer Program** ($99/year) if not already enrolled
- [ ] **3.2 — Register App ID:** `rocks.moolah.app` for iOS
- [ ] **3.3 — Register CloudKit container**
  - Go to Certificates, Identifiers & Profiles → CloudKit Containers
  - Create container `iCloud.rocks.moolah.app`
  - Enable iCloud capability on the `rocks.moolah.app` App ID with CloudKit service
- [ ] **3.4 — Create App Store Connect app record**
  - Set app name, primary language, bundle ID, SKU
  - Configure pricing (free)
  - No metadata polish needed for TestFlight-only
- [ ] **3.5 — Create App Store Connect API Key**
  - Go to Users & Access → Integrations → App Store Connect API
  - Create key with "App Manager" role
  - Download the `.p8` file — it can only be downloaded once
  - Note the Key ID and Issuer ID

---

## Phase 4: GitHub Secrets & Certificates (Requires Developer Account)

### 4.1 — Match Certificates Repository

- [ ] **4.1.1 — Create a private git repo** for Match certificates (e.g., `github.com/ajsutton/moolah-certificates`)
- [ ] **4.1.2 — Run `fastlane match init`** to generate initial certificates and profiles
- [ ] **4.1.3 — Verify provisioning profiles** include the iCloud/CloudKit entitlement (automatic if App ID has iCloud enabled in Phase 3.3)

### 4.2 — GitHub Secrets

- [ ] **Add the following secrets** to the GitHub repository (Settings → Secrets → Actions):

| Secret | Description |
|--------|-------------|
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_KEY_CONTENT` | Base64-encoded `.p8` private key content (use `base64 -i AuthKey_XXXXXX.p8 \| pbcopy`) |
| `MATCH_GIT_URL` | URL of the private certificates repo |
| `MATCH_PASSWORD` | Passphrase to decrypt Match certificates (generate with `openssl rand -base64 32`) |
| `MATCH_GIT_BASIC_AUTHORIZATION` | Base64-encoded `username:PAT` for Match repo access (use `echo -n "ajsutton:ghp_TOKEN" \| base64`) |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID |

### 4.3 — GitHub Environment Protection

- [ ] **Create GitHub Environment** `testflight` with protection rules:
  - Deployment branches: tags only (`v*`)

### 4.4 — CI Security

- [ ] **4.4.1 — Verify fork PR settings:** Settings → Actions → General → "Require approval for all outside collaborators" (default)
- [ ] **4.4.2 — Pin third-party actions to SHA** in release workflows for supply chain protection
- [ ] **4.4.3 — Create a fine-grained PAT** for `MATCH_GIT_BASIC_AUTHORIZATION` scoped to only the certificates repo with `Contents: Read` permission. Set an expiry (e.g., 1 year)

---

## Phase 5: First TestFlight Build

- [ ] **5.1 — Push a version tag:** `git tag v1.0.0 && git push origin v1.0.0`
- [ ] **5.2 — Approve the environment deployment** in GitHub Actions when prompted
- [ ] **5.3 — Verify the TestFlight build** appears in App Store Connect / TestFlight app
- [ ] **5.4 — Install on devices** via TestFlight app and verify:
  - Only iCloud profile creation is available (remote backend hidden)
  - iCloud sync works across devices
  - All core features work (accounts, transactions, categories, etc.)
- [ ] **5.5 — Verify monthly auto-tag** by triggering `monthly-tag.yml` manually via `workflow_dispatch`

---

# Milestone 2: Full App Store Deployment (Future)

Everything below is only needed if you decide to publish Moolah on the App Store for others to use. None of this is required for personal TestFlight use.

---

## Phase 6: Disable Remote Backend for App Store Builds

App Store builds must be iCloud/CloudKit only. This eliminates several App Store compliance requirements: Sign in with Apple (Guideline 4.8), complex account deletion flows, demo account preparation, IPv6 testing for custom servers, and simplifies the privacy policy.

### 6.1 — Add `APPSTORE_BUILD` Compilation Condition

**File: `project.yml`**

Add `APPSTORE_BUILD` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for Release builds on both iOS and macOS targets. This condition gates all remote backend UI and instantiation.

**What to change in `project.yml`:**
- In `Moolah_iOS` target settings, add a `configs` block under `settings` with a `Release` configuration that sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS: APPSTORE_BUILD`
- Do the same for `Moolah_macOS`

**Result:** In Debug builds, the full app (CloudKit + remote) is available for development. In Release builds (App Store), only CloudKit profiles can be created.

**Note:** This will also affect TestFlight builds since they use the Release configuration. If you want to keep both backends available on TestFlight while gating for App Store, consider adding a separate `AppStore` build configuration instead of using `Release`. Alternatively, accept that TestFlight builds will also be iCloud-only once this is enabled.

### 6.2 — Gate Profile Setup UI

**File: `Features/Profiles/Views/ProfileSetupView.swift`**

Wrap the "Sign in to Moolah" button and "Use a custom server" button/fields in `#if !APPSTORE_BUILD` blocks. In App Store builds, only the "Store in iCloud" button and its form fields should appear.

**What to change:**
- The "Sign in to Moolah" button (both the `showICloudForm` and `!showICloudForm` branches) → wrap in `#if !APPSTORE_BUILD`
- The "Use a custom server" button → wrap in `#if !APPSTORE_BUILD`
- The `customServerFields` section → wrap in `#if !APPSTORE_BUILD`
- In App Store builds, auto-expand the iCloud form (since it's the only option) — set `showICloudForm = true` by default or skip the initial button and show the form directly

### 6.3 — Gate Profile Form UI

**File: `Features/Profiles/Views/ProfileFormView.swift`**

Wrap the "Moolah" and "Custom Server" buttons in the backend type selection section in `#if !APPSTORE_BUILD`. In App Store builds, auto-select `.cloudKit` and hide the type picker entirely.

**What to change:**
- The `.moolah` Button → wrap in `#if !APPSTORE_BUILD`
- The `.remote` Button → wrap in `#if !APPSTORE_BUILD`
- The custom server form fields section (`if selectedType == .remote`) → wrap in `#if !APPSTORE_BUILD`
- Set `selectedType` default to `.cloudKit` in App Store builds
- In `save()`, the `.moolah` and `.remote` switch cases → wrap in `#if !APPSTORE_BUILD`
- In `canAdd`, the `.moolah` and `.remote` cases → wrap in `#if !APPSTORE_BUILD`

### 6.4 — Guard Backend Instantiation

**File: `App/ProfileSession.swift`**

Add a compile-time guard in `ProfileSession.init` to prevent `RemoteBackend` instantiation in App Store builds. This is a safety net in case a remote profile somehow exists.

**What to change:**
- In the `switch profile.backendType` block, wrap the `.remote, .moolah` case body in `#if !APPSTORE_BUILD` / `#else fatalError("Remote backend is not available in App Store builds")` / `#endif`
- Alternatively, fall back to a read-only error state rather than crashing

### 6.5 — Compile-Time Exclusion of Remote Backend Code (Optional)

**Files: `Backends/Remote/` directory**

Optionally, wrap the entire `RemoteBackend` implementation files with `#if !APPSTORE_BUILD` to reduce binary size. Not strictly required since the UI and instantiation guards prevent usage, but it's a clean approach.

### 6.6 — Verify the Gate Works

**Verification steps:**
1. Run `just generate` to regenerate the Xcode project
2. Build in Debug configuration → confirm all three profile types are available in UI
3. Build in Release configuration → confirm only iCloud profile creation is available
4. Run tests (which use Debug config) → confirm all existing tests still pass

---

## Phase 7: App Store Readiness — Content & Compliance

### 7.1 — Add Privacy Policy (Guideline 5.1.1(i)) — BLOCKER

A privacy policy is required for all App Store apps. With remote backend disabled, the policy is simpler — data only lives on-device and in the user's iCloud account.

- [ ] **7.1.1 — Write the privacy policy** covering:
  - What financial data is collected (transaction descriptions, amounts, categories, account names)
  - How it's stored (locally on device, synced via user's own iCloud/CloudKit account)
  - Retention and deletion (user controls all data; deleting the app or iCloud data removes everything)
  - No data shared with third parties (no analytics, tracking, or advertising SDKs)
  - No server-side data collection (iCloud-only, Apple handles sync infrastructure)
- [ ] **7.1.2 — Host the privacy policy** at a public URL (e.g., `moolah.rocks/privacy`)
- [ ] **7.1.3 — Add a "Privacy Policy" link** in the app's Settings screen
- [ ] **7.1.4 — Add the privacy policy URL** in App Store Connect metadata

### 7.2 — Add Contact / Support Information (Guideline 1.5) — BLOCKER

- [ ] **7.2.1 — Set up a support email** (e.g., `support@moolah.rocks`)
- [ ] **7.2.2 — Add "Support" section in Settings** with the support email and/or support URL
- [ ] **7.2.3 — Add the support URL** in App Store Connect metadata

### 7.3 — Verify Account Deletion Flow (Guideline 5.1.1(v))

With remote backend disabled, CloudKit profiles already have full deletion support via `ProfileDataDeleter` with cascade delete.

- [ ] **7.3.1 — Verify the deletion UI** is clear and discoverable in Settings
- [ ] **7.3.2 — Test the deletion flow** end-to-end: create a CloudKit profile → add data → delete profile → verify data is gone

### 7.4 — Verify iPad Layout (Guideline 2.4.1)

- [ ] **7.4.1 — Test on iPad simulators** (multiple sizes: iPad mini, iPad Air, iPad Pro 12.9")
- [ ] **7.4.2 — Verify `NavigationSplitView`** works correctly on iPad
- [ ] **7.4.3 — Check forms, lists, and charts** use available screen space well
- [ ] **7.4.4 — Fix any layout issues** found

### 7.5 — Prepare App Review Notes

- [ ] **7.5.1 — Write App Review notes** explaining:
  - App is a personal budgeting organizer (not a financial service)
  - Data is stored locally and in user's iCloud account only
  - No account creation required — create a profile and start using immediately
  - If submitting as individual developer: note that the app does not hold funds or execute real transactions
- [ ] **7.5.2 — Consider first-launch sample data** or clear instructions for reviewers

### 7.6 — Legal Entity Evaluation (Guideline 5.1.1(ix))

- [ ] **7.6.1 — Evaluate whether to submit as individual or organization**
  - With remote backend disabled, Moolah is clearly a personal organizer, not a financial service
  - If submitting as individual: include explanation in App Review notes

---

## Phase 8: App Store Release Automation

### 8.1 — Add App Store Lane to Fastfile

Add the `release` lane to `fastlane/Fastfile`:

```ruby
desc "Build and upload iOS app to App Store"
lane :release do
  certificates

  api_key = app_store_connect_api_key(
    key_id: ENV["ASC_KEY_ID"],
    issuer_id: ENV["ASC_ISSUER_ID"],
    key_content: ENV["ASC_KEY_CONTENT"],
    is_key_content_base64: true
  )

  increment_build_number(
    build_number: latest_testflight_build_number(api_key: api_key) + 1
  )

  build_app(
    scheme: "Moolah-iOS",
    export_method: "app-store",
    output_directory: "./build",
    output_name: "Moolah.ipa"
  )

  upload_to_app_store(
    api_key: api_key,
    submit_for_review: false,
    automatic_release: false,
    phased_release: true,
    precheck_include_in_app_purchases: false
  )
end
```

### 8.2 — Add macOS Lanes to Fastfile

```ruby
platform :mac do
  before_all do
    setup_ci
  end

  desc "Sync certificates and profiles for macOS"
  lane :certificates do
    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_CONTENT"],
      is_key_content_base64: true
    )

    match(
      type: "appstore",
      platform: "macos",
      app_identifier: "rocks.moolah.app",
      api_key: api_key,
      readonly: is_ci
    )

    match(
      type: "developer_id",
      platform: "macos",
      app_identifier: "rocks.moolah.app",
      api_key: api_key,
      readonly: is_ci
    )
  end

  desc "Build and notarize macOS app for direct distribution"
  lane :beta do
    certificates

    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_CONTENT"],
      is_key_content_base64: true
    )

    build_app(
      scheme: "Moolah-macOS",
      export_method: "developer-id",
      output_directory: "./build",
      output_name: "Moolah.app"
    )

    notarize(
      package: "./build/Moolah.app",
      api_key: api_key
    )
  end
end
```

### 8.3 — App Store Release Workflow

- [ ] **Create `.github/workflows/release.yml`:**

```yaml
name: App Store Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Version to release (e.g., 1.2.0)"
        required: true
        type: string
      submit_for_review:
        description: "Submit for App Store review after upload"
        required: false
        type: boolean
        default: false

permissions:
  contents: write

jobs:
  release:
    name: Build & Upload to App Store
    runs-on: macos-26
    timeout-minutes: 30
    environment: production

    steps:
      - uses: actions/checkout@v6
        with:
          ref: main

      - name: Install tools
        run: brew install xcodegen just

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
          bundler-cache: true

      - name: Update marketing version
        run: |
          sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"${{ inputs.version }}\"/" project.yml

      - name: Deploy to App Store
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
          MATCH_GIT_URL: ${{ secrets.MATCH_GIT_URL }}
          MATCH_PASSWORD: ${{ secrets.MATCH_PASSWORD }}
          MATCH_GIT_BASIC_AUTHORIZATION: ${{ secrets.MATCH_GIT_BASIC_AUTHORIZATION }}
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CODE_SIGN_STYLE: "Manual"
          FL_UPLOAD_TO_APP_STORE_SUBMIT_FOR_REVIEW: ${{ inputs.submit_for_review }}
        run: bundle exec fastlane ios release

      - name: Upload IPA artifact
        uses: actions/upload-artifact@v4
        with:
          name: Moolah-${{ inputs.version }}.ipa
          path: build/Moolah.ipa

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: v${{ inputs.version }}
          name: Moolah ${{ inputs.version }}
          generate_release_notes: true
          draft: true
```

### 8.4 — Production GitHub Environment

- [ ] **Create GitHub Environment** `production` with protection rules:
  - Deployment branches: `main` only

### 8.5 — Additional Justfile Targets

```just
# Build and notarize macOS app for direct distribution
notarize-mac: generate
    bundle exec fastlane mac beta
```

### 8.6 — Pre-Submission Checklist

Before the first App Store submission, verify:
- [ ] Privacy policy is live at the hosted URL
- [ ] Support/contact info is accessible in-app
- [ ] Account deletion flow works for CloudKit profiles
- [ ] iPad layout is acceptable
- [ ] TestFlight build shows only iCloud profile option (remote backend is hidden)
- [ ] App Review notes are written and entered in App Store Connect
- [ ] App Store metadata is complete (description, keywords, screenshots, category)

---

## Phase 9: Future Enhancements

- [ ] **9.1 — Re-enable remote backend** — Remove the `APPSTORE_BUILD` gate, implement Sign in with Apple, proper account deletion, etc.
- [ ] **9.2 — App Store metadata automation** — Fastlane `deliver` to manage screenshots, descriptions, keywords from version-controlled files
- [ ] **9.3 — Automated changelog** — Generate release notes from conventional commits
- [ ] **9.4 — Mac App Store distribution** — Separate Fastlane lane for Mac App Store
- [ ] **9.5 — Phased rollout** — 1% → 2% → 5% → 10% → 20% → 50% → 100% over 7 days
- [ ] **9.6 — dSYM upload** — Debug symbols to crash reporting (Sentry, Firebase Crashlytics)
- [ ] **9.7 — Precheck validation** — Fastlane `precheck` to validate metadata before submission

---

## File Checklist

### Milestone 1 (TestFlight)

New files to create:

| File | Purpose | Phase |
|------|---------|-------|
| `Gemfile` | Ruby dependencies (Fastlane) | 2.1 |
| `fastlane/.env` | Opt out of Fastlane usage reporting | 2.1 |
| `fastlane/Appfile` | App identifier and team configuration | 2.2 |
| `fastlane/Matchfile` | Match certificate sync configuration | 2.2 |
| `fastlane/Fastfile` | Build, sign, and upload automation (iOS beta lane) | 2.3 |
| `App/Moolah.entitlements` | App Sandbox, network, and iCloud/CloudKit entitlements | 1.3 |
| `.github/workflows/testflight.yml` | TestFlight deployment on tag push | 2.4 |
| `.github/workflows/monthly-tag.yml` | Monthly auto-tag to keep TestFlight fresh | 2.5 |

Files to modify:

| File | Change | Phase |
|------|--------|-------|
| `project.yml` | Add `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, release-config overrides, entitlements path, iCloud capability | 1.1, 1.2, 1.4 |
| `App/Info.plist` | Replace hardcoded versions with build setting variables | 1.1 |
| `App/MoolahApp.swift` | Configure `ModelContainer` with `cloudKitDatabase: .automatic` | 1.5 |
| `justfile` | Add `certificates`, `testflight`, `bump-version` targets | 2.6 |
| `.gitignore` | Add Fastlane artifacts, `vendor/bundle` | 2.1 |

### Milestone 2 (App Store) — additional files

| File | Purpose | Phase |
|------|---------|-------|
| `.github/workflows/release.yml` | App Store deployment (manual trigger) | 8.3 |
| `Features/Profiles/Views/ProfileSetupView.swift` | Gate remote backend UI with `#if !APPSTORE_BUILD` | 6.2 |
| `Features/Profiles/Views/ProfileFormView.swift` | Gate remote backend UI with `#if !APPSTORE_BUILD` | 6.3 |
| `App/ProfileSession.swift` | Guard against RemoteBackend instantiation in App Store builds | 6.4 |
| Settings view (TBD) | Privacy policy link and support/contact info | 7.1, 7.2 |

---

## Security Considerations

### Secrets & Key Material

- **Never commit** the `.p8` API key file, certificates, or provisioning profiles to the main repo
- **`fastlane/api_key.json` is gitignored** — added to `.gitignore` before any Fastlane files are created
- **Match encrypts** all certificates and profiles with `MATCH_PASSWORD` before storing in the certificates repo
- **API keys** are stored as GitHub Actions secrets, never in code
- **The certificates repo** (`moolah-certificates`) must be private and access-restricted
- **Rotate the API key** if it is ever exposed (revoke in App Store Connect → create new key → update secret)
- **Use `readonly: is_ci`** in Match to prevent CI from accidentally creating new certificates

### CI Pipeline Security

- **Fork PRs cannot access secrets** — `ci.yml` uses `pull_request` (not `pull_request_target`)
- **Environment protection gates** — TestFlight workflow requires manual approval via GitHub Environment
- **Least-privilege `GITHUB_TOKEN`** — Workflows declare minimal `permissions:`
- **Third-party action pinning** — Pin to commit SHAs in release workflows
- **PAT scope restriction** — Fine-grained token scoped to certificates repo only
- **No secret logging** — Fastlane and GitHub Actions mask secrets automatically
- **Tag protection** — Consider enabling tag protection rules so only maintainers can push `v*` tags

---

## Cost & Dependencies

| Item | Cost | Notes |
|------|------|-------|
| Apple Developer Program | $99/year | Required for TestFlight and App Store |
| GitHub Actions (macOS) | Free | Free for public repos (unlimited minutes on standard runners) |
| Private certificates repo | Free | GitHub private repos are free |
| Fastlane | Free | Open-source |
