# iOS Release Automation Plan

**Goal:** Automate the build, signing, and distribution pipeline for Moolah on iOS (App Store / TestFlight) and macOS (direct distribution / Mac App Store), starting from the current state of zero release infrastructure.

**Current State:**
- GitHub Actions CI runs tests and linting only (`.github/workflows/ci.yml`)
- XcodeGen generates `Moolah.xcodeproj` from `project.yml`
- Code signing is environment-variable driven but not configured for distribution
- No Fastlane, no provisioning profiles, no App Store Connect integration
- Version is hardcoded to `1.0` (build `1`) in `App/Info.plist`
- Bundle ID: `rocks.moolah.app` (shared across iOS and macOS targets)

---

## Architecture Overview

```
Tag v1.2.0          GitHub Actions              App Store Connect
    │                    │                            │
    └──► release.yml ──► Fastlane ──► TestFlight ──► App Store
              │              │
              │         match (signing)
              │         gym (archive)
              │         pilot (upload)
              │
         XcodeGen generate
```

**Key decisions:**
- **Fastlane** for build/sign/upload orchestration (industry standard, well-maintained)
- **Fastlane Match** for code signing (git-encrypted certificate storage)
- **App Store Connect API Key** for authentication (no passwords, no 2FA prompts)
- **Git tags** trigger release builds (e.g., `v1.2.0`)
- **Build numbers** auto-increment from App Store Connect (latest + 1)

---

## Phase 1: Apple Developer Account Setup (Manual, One-Time)

These steps must be done manually in the Apple Developer portal and App Store Connect before any automation can work.

- [ ] **1.1 — Enroll in Apple Developer Program** ($99/year) if not already enrolled
- [ ] **1.2 — Register App IDs**
  - `rocks.moolah.app` for iOS
  - `rocks.moolah.app` for macOS (may share the same App ID if using universal purchase)
- [ ] **1.3 — Create App Store Connect app record**
  - Set app name, primary language, bundle ID, SKU
  - Configure pricing (even if free)
- [ ] **1.4 — Register CloudKit container**
  - Go to Certificates, Identifiers & Profiles → CloudKit Containers
  - Create container `iCloud.rocks.moolah.app`
  - Enable iCloud capability on the `rocks.moolah.app` App ID with CloudKit service
- [ ] **1.5 — Create App Store Connect API Key**
  - Go to Users & Access → Integrations → App Store Connect API
  - Create key with "App Manager" role
  - Download the `.p8` file — it can only be downloaded once
  - Note the Key ID and Issuer ID
- [ ] **1.6 — Create a private git repo for Match certificates**
  - e.g., `github.com/ajsutton/moolah-certificates` (private)
  - This will store encrypted certificates and provisioning profiles

---

## Phase 2: Fastlane Setup

### 2.1 — Install Fastlane

- [ ] **Add `Gemfile`** to project root:

```ruby
source "https://rubygems.org"

gem "fastlane"
gem "xcode-install" # optional, for Xcode version management
```

- [ ] **Opt out of Fastlane usage reporting** by setting the environment variable in the project. Add to `.env` or export in CI:

```bash
export FASTLANE_OPT_OUT_USAGE=YES
```

Alternatively, create a `fastlane/.env` file (checked into the repo) with:

```
FASTLANE_OPT_OUT_USAGE=YES
FASTLANE_SKIP_UPDATE_CHECK=1
```

- [ ] **Add to `.gitignore` (do this BEFORE creating any Fastlane config files):**

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

- [ ] **Create `fastlane/Appfile`:**

```ruby
app_identifier("rocks.moolah.app")
apple_id(ENV["APPLE_ID"])  # only needed for deliver, not for API key auth
team_id(ENV["DEVELOPMENT_TEAM"])
```

- [ ] **Create `fastlane/Matchfile`:**

```ruby
git_url(ENV["MATCH_GIT_URL"])  # e.g., "https://github.com/ajsutton/moolah-certificates.git"

storage_mode("git")

type("appstore")  # default type

app_identifier("rocks.moolah.app")
team_id(ENV["DEVELOPMENT_TEAM"])

# API key is passed directly from env vars in the Fastfile — no local file needed
```

- [ ] **`fastlane/api_key.json` (local development only, already gitignored in 2.1):**

  If you need to run Fastlane locally (not in CI), create this file manually. It is already in `.gitignore` from step 2.1. Never commit it.

```json
{
  "key_id": "YOUR_KEY_ID",
  "issuer_id": "YOUR_ISSUER_ID",
  "key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----",
  "in_house": false
}
```

### 2.3 — Fastfile (Core Automation)

- [ ] **Create `fastlane/Fastfile`:**

```ruby
default_platform(:ios)

before_all do
  # Regenerate Xcode project from project.yml
  sh("cd .. && just generate")
end

# ─── iOS ────────────────────────────────────────────────────────

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
      submit_for_review: false,  # manual review submission initially
      automatic_release: false,
      phased_release: true,
      precheck_include_in_app_purchases: false
    )
  end
end

# ─── macOS ──────────────────────────────────────────────────────

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

---

## Phase 3: Project Configuration Changes

### 3.1 — Versioning

- [ ] **Switch to `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` build settings** instead of hardcoded `Info.plist` values. Update `project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0.0"       # Semantic version (shown to users)
    CURRENT_PROJECT_VERSION: "1"     # Build number (auto-incremented by Fastlane)
```

- [ ] **Update `App/Info.plist`** to use build setting variables:

```xml
<key>CFBundleShortVersionString</key>
<string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key>
<string>$(CURRENT_PROJECT_VERSION)</string>
```

### 3.2 — Signing Configuration for Distribution

- [ ] **Update `project.yml`** to support both development and distribution signing:

```yaml
# The existing env-var approach works. Fastlane Match will set:
#   CODE_SIGN_STYLE=Manual
#   CODE_SIGN_IDENTITY="Apple Distribution"  (or "Developer ID Application" for macOS)
#   PROVISIONING_PROFILE_SPECIFIER="match AppStore rocks.moolah.app"
#   DEVELOPMENT_TEAM="<your-team-id>"
```

No changes needed — the current env-driven approach in `project.yml` is already compatible with Fastlane Match.

### 3.3 — macOS Hardened Runtime

- [ ] **Enable hardened runtime for macOS release builds.** Currently `ENABLE_HARDENED_RUNTIME: NO` in `project.yml`. Add a Release configuration override:

```yaml
Moolah_macOS:
  settings:
    configs:
      Release:
        ENABLE_HARDENED_RUNTIME: YES
```

Hardened runtime is required for macOS notarization and App Store submission.

### 3.4 — Entitlements & iCloud/CloudKit Sync

The app uses SwiftData with CloudKit-backed models (`*Record` types) for cross-device iCloud syncing. This requires entitlements, a CloudKit container, and project configuration.

#### 3.4.1 — Apple Developer Portal (Manual, One-Time)

- [ ] **Register a CloudKit container** in the Apple Developer portal: `iCloud.rocks.moolah.app`
- [ ] **Enable iCloud capability** for App ID `rocks.moolah.app` with CloudKit service selected

#### 3.4.2 — Entitlements Files

- [ ] **Create `App/Moolah.entitlements`** (shared by both iOS and macOS targets):

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

#### 3.4.3 — Project Configuration

- [ ] **Update `project.yml`** to wire entitlements and iCloud capability to both targets:

```yaml
# In each target's settings:
settings:
  base:
    CODE_SIGN_ENTITLEMENTS: App/Moolah.entitlements

# In each target's capabilities (XcodeGen syntax):
attributes:
  SystemCapabilities:
    com.apple.iCloud:
      enabled: 1
```

#### 3.4.4 — SwiftData CloudKit Configuration

- [ ] **Update `MoolahApp.init()`** to enable CloudKit sync in the `ModelConfiguration`:

```swift
let config = ModelConfiguration(
    cloudKitDatabase: .automatic  // Syncs via iCloud when signed in, local-only otherwise
)
container = try ModelContainer(for: schema, configurations: [config])
```

Using `.automatic` means the app works offline and without an iCloud account (local storage only), and syncs across devices when signed in to iCloud.

#### 3.4.5 — Provisioning Profiles

- [ ] **Update Fastlane Match** to generate provisioning profiles that include the iCloud/CloudKit entitlement. Match handles this automatically as long as the App ID has iCloud enabled in the developer portal (done in 3.4.1)

---

## Phase 4: GitHub Actions Release Workflow

### 4.1 — GitHub Secrets Configuration

- [ ] **Add the following secrets** to the GitHub repository (Settings → Secrets → Actions):

| Secret | Description |
|--------|-------------|
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_KEY_CONTENT` | Base64-encoded `.p8` private key content (use `base64 -i AuthKey_XXXXXX.p8 \| pbcopy`) |
| `MATCH_GIT_URL` | URL of the private certificates repo (e.g., `https://github.com/ajsutton/moolah-certificates.git`) |
| `MATCH_PASSWORD` | Passphrase to decrypt Match certificates (generate a strong random password, e.g., `openssl rand -base64 32`) |
| `MATCH_GIT_BASIC_AUTHORIZATION` | Base64-encoded `username:PAT` for Match repo access (use `echo -n "ajsutton:ghp_TOKEN" \| base64`) |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID (found in Apple Developer portal → Membership) |

**Setup steps:**
1. Go to GitHub repo → Settings → Secrets and variables → Actions
2. Add each secret above using "New repository secret"
3. Verify secrets are stored (they show as `***` in logs — GitHub automatically masks them)
4. The PAT for `MATCH_GIT_BASIC_AUTHORIZATION` needs only `repo` scope (read access to the private certificates repo)

### 4.2 — CI Security: Protecting Secrets from External PRs

GitHub Actions exposes repository secrets to workflows triggered by events from the same repository. However, **pull requests from forks do NOT have access to secrets** by default — this is critical for public repos.

- [ ] **4.2.1 — Verify repository settings:**
  - Go to Settings → Actions → General → "Fork pull request workflows from outside collaborators"
  - Set to **"Require approval for all outside collaborators"** (default, do not change)
  - This ensures fork PRs cannot run workflows without maintainer approval

- [ ] **4.2.2 — Use `environment` protection for release workflows:**

  Create two GitHub Environments (Settings → Environments):

  | Environment | Protection Rules |
  |-------------|-----------------|
  | `testflight` | Required reviewers: at least 1 (yourself). Deployment branches: tags only (`v*`) |
  | `production` | Required reviewers: at least 1 (yourself). Deployment branches: `main` only |

  This adds an approval gate before any release workflow can access secrets, even if triggered accidentally.

- [ ] **4.2.3 — Never use `pull_request_target` with secrets:**

  The existing `ci.yml` correctly uses `pull_request` (not `pull_request_target`), which is safe — fork PRs cannot access secrets. **Never change CI to `pull_request_target`** unless you fully understand the implications (it runs with the base branch's code but the PR's ref, which can be exploited).

- [ ] **4.2.4 — Pin third-party actions to SHA (supply chain protection):**

  Instead of using mutable tags like `@v6`, pin actions to their full commit SHA to prevent supply chain attacks via tag re-pointing. Use Dependabot or Renovate to keep them updated.

  ```yaml
  # Instead of:
  - uses: actions/checkout@v6
  # Use:
  - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v6.0.0
  ```

  At minimum, pin these in the release workflows (the CI workflow is lower risk since it has no secrets).

- [ ] **4.2.5 — Restrict `GITHUB_TOKEN` permissions:**

  Add explicit permissions to each workflow to follow least-privilege:

  ```yaml
  permissions:
    contents: read  # Default — only escalate where needed
  ```

  The release workflow needs `contents: write` for creating GitHub releases. Declare this at the job level, not the workflow level.

- [ ] **4.2.6 — Audit `MATCH_GIT_BASIC_AUTHORIZATION` PAT scope:**
  - Create a **fine-grained PAT** (not classic) scoped to only the `moolah-certificates` repo with `Contents: Read` permission
  - Set an expiry (e.g., 1 year) and rotate before it expires
  - If using a classic PAT, limit to `repo` scope only

### 4.3 — TestFlight Workflow (on tag push)

- [ ] **Create `.github/workflows/testflight.yml`:**

```yaml
name: TestFlight

on:
  push:
    tags:
      - "v*"  # Trigger on version tags like v1.0.0, v1.2.3-beta.1

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
          bundler-cache: true  # caches gems from Gemfile.lock

      - name: Set version from tag
        run: |
          VERSION=${GITHUB_REF_NAME#v}   # Strip "v" prefix: v1.2.0 → 1.2.0
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

### 4.3 — App Store Release Workflow (manual trigger)

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
  contents: write  # Needed for creating GitHub releases

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

---

## Phase 5: Justfile Targets

- [ ] **Add release-related targets** to `justfile`:

```just
# Sync code signing certificates (runs Match)
certificates:
    bundle exec fastlane ios certificates

# Build and upload to TestFlight
testflight: generate
    bundle exec fastlane ios beta

# Build and notarize macOS app for direct distribution
notarize-mac: generate
    bundle exec fastlane mac beta

# Bump marketing version (usage: just bump-version 1.2.0)
bump-version version:
    sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: "{{version}}"/' project.yml
    just generate
```

---

## Phase 6: Release Workflow Process

### Releasing a New Version

1. **Prepare:** Ensure `main` is green (CI passes, all tests pass)
2. **Bump version:** `just bump-version 1.2.0` and commit
3. **Tag:** `git tag v1.2.0 && git push origin v1.2.0`
4. **Automatic:** GitHub Actions triggers `testflight.yml` → builds → uploads to TestFlight
5. **Test:** QA / beta testers validate the TestFlight build
6. **Ship:** Trigger `release.yml` workflow manually with the version number
7. **Review:** App goes through Apple review (or auto-submits if configured)

### Hotfix Process

1. Branch from the release tag: `git checkout -b hotfix/1.2.1 v1.2.0`
2. Fix, test, merge to `main`
3. Tag `v1.2.1` and push — same automation kicks in

---

## Phase 7: Build Caching

GitHub Actions macOS runners cost ~10x Linux runners, so caching is important to keep build times and costs down.

- [ ] **7.1 — Add DerivedData caching** to both CI and release workflows. Use `irgaly/xcode-cache` instead of `actions/cache` — it preserves file timestamps with nanosecond precision, which Xcode's incremental build system depends on:

```yaml
- uses: irgaly/xcode-cache@v1
  with:
    key: xcode-derived-${{ runner.os }}-${{ hashFiles('project.yml', '**/*.swift') }}
    restore-keys: xcode-derived-${{ runner.os }}-
```

- [ ] **7.2 — Add SPM dependency caching** (if SPM packages are added in the future):

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/Library/Caches/org.swift.swiftpm
      ~/Library/org.swift.swiftpm
    key: spm-${{ runner.os }}-${{ hashFiles('**/Package.resolved') }}
    restore-keys: spm-${{ runner.os }}-
```

- [ ] **7.3 — Ruby gem caching** is handled automatically by `ruby/setup-ruby@v1` with `bundler-cache: true` (already included in the workflows above)

---

## Phase 8: Future Enhancements

These are not required for the initial release pipeline but are valuable additions over time.

- [ ] **8.1 — App Store Connect Webhooks (WWDC 2025)** — Register webhook endpoints to receive push notifications for build processing completion, TestFlight review status, and App Store review status changes. This replaces polling and enables event-driven pipelines (e.g., auto-notify QA when a TestFlight build finishes processing)
- [ ] **8.2 — App Store metadata automation** — Use Fastlane `deliver` to manage screenshots, descriptions, keywords, and release notes from version-controlled files in `fastlane/metadata/`
- [ ] **8.3 — Automated changelog** — Generate release notes from conventional commit messages or PR titles using `git-cliff` or GitHub's auto-generated release notes
- [ ] **8.4 — Mac App Store distribution** — Add a separate Fastlane lane for Mac App Store submission (requires App Sandbox entitlements)
- [ ] **8.5 — Phased rollout configuration** — Configure automatic phased rollout (1% → 2% → 5% → 10% → 20% → 50% → 100% over 7 days). Can be paused at any stage for up to 30 days
- [ ] **8.6 — Slack/Discord notifications** — Notify on successful TestFlight uploads or App Store review status changes
- [ ] **8.7 — dSYM upload** — Upload debug symbols to a crash reporting service (Sentry, Firebase Crashlytics) as part of the release lane
- [ ] **8.8 — Separate bundle IDs per platform** — If iOS and macOS need separate App Store listings, use `rocks.moolah.app.ios` and `rocks.moolah.app.macos`
- [ ] **8.9 — Precheck validation** — Add Fastlane's `precheck` action to validate metadata against known App Store rejection reasons before submission
- [ ] **8.10 — TestFlight feedback API (WWDC 2025)** — Programmatically retrieve TestFlight feedback (screenshots, crash reports) and integrate with issue tracking

---

## File Checklist

New files to create:

| File | Purpose |
|------|---------|
| `Gemfile` | Ruby dependencies (Fastlane) |
| `fastlane/Appfile` | App identifier and team configuration |
| `fastlane/.env` | Opt out of Fastlane usage reporting and skip update checks |
| `fastlane/Matchfile` | Match certificate sync configuration |
| `fastlane/Fastfile` | Build, sign, and upload automation |
| `App/Moolah.entitlements` | App Sandbox, network, and iCloud/CloudKit entitlements |
| `.github/workflows/testflight.yml` | TestFlight deployment on tag push |
| `.github/workflows/release.yml` | App Store deployment (manual trigger) |

Files to modify:

| File | Change |
|------|--------|
| `project.yml` | Add `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, release-config overrides, entitlements path, iCloud capability |
| `App/Info.plist` | Replace hardcoded versions with build setting variables |
| `App/MoolahApp.swift` | Configure `ModelContainer` with `cloudKitDatabase: .automatic` for iCloud sync |
| `justfile` | Add `certificates`, `testflight`, `notarize-mac`, `bump-version` targets |
| `.gitignore` | Add Fastlane artifacts, `vendor/bundle`, `fastlane/api_key.json` |

---

## Security Considerations

### Secrets & Key Material

- **Never commit** the `.p8` API key file, certificates, or provisioning profiles to the main repo
- **`fastlane/api_key.json` is gitignored** — added to `.gitignore` before any Fastlane files are created (Phase 2.1)
- **Match encrypts** all certificates and profiles with `MATCH_PASSWORD` before storing in the certificates repo
- **API keys** are stored as GitHub Actions secrets, never in code
- **The certificates repo** (`moolah-certificates`) must be private and access-restricted to only the repo owner
- **Rotate the API key** if it is ever exposed (revoke in App Store Connect → create new key → update `ASC_KEY_CONTENT` secret)
- **Use `readonly: is_ci`** in Match to prevent CI from accidentally creating new certificates

### CI Pipeline Security

- **Fork PRs cannot access secrets** — GitHub does not expose repository secrets to `pull_request` events from forks (verified: `ci.yml` uses `pull_request`, not `pull_request_target`)
- **Environment protection gates** — Release workflows require manual approval via GitHub Environments (`testflight`, `production`) before secrets are exposed
- **Least-privilege `GITHUB_TOKEN`** — Workflows declare minimal `permissions:` (read-only by default, write only where needed)
- **Third-party action pinning** — Release workflows should pin actions to full commit SHAs to prevent supply chain attacks via tag manipulation
- **PAT scope restriction** — The `MATCH_GIT_BASIC_AUTHORIZATION` PAT should be a fine-grained token scoped to only the certificates repo with read-only content access
- **No secret logging** — Fastlane and GitHub Actions both mask secrets in logs automatically; never use `echo $SECRET` or `print` in lanes
- **Tag protection** — Consider enabling tag protection rules (Settings → Tags) so only maintainers can push `v*` tags, preventing unauthorized release triggers

---

## Cost & Dependencies

| Item | Cost | Notes |
|------|------|-------|
| Apple Developer Program | $99/year | Required for App Store distribution |
| GitHub Actions (macOS) | ~$0.08/min | macOS runners are 10x Linux pricing; budget ~$2-5 per release build |
| Private certificates repo | Free | GitHub private repos are free |
| Fastlane | Free | Open-source |
