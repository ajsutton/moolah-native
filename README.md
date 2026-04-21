# Moolah — Native iOS/macOS App

A universal personal finance app for iPhone and Mac. Tracks accounts, transactions,
categories, earmarks (savings goals), scheduled payments, and provides analysis and
reporting. Supports two backend modes: iCloud/CloudKit for local-first sync across
devices, and the [ajsutton/moolah-server](https://github.com/ajsutton/moolah-server)
REST API at `https://moolah.rocks/api/`.

## Requirements

| Tool | Version |
|---|---|
| Xcode | 26+ |
| iOS deployment target | 26+ |
| macOS deployment target | 26+ |
| XcodeGen | Latest (`brew install xcodegen`) |
| just | Latest (`brew install just`) |
| SwiftLint | 0.55+ (`brew install swiftlint`) — run by `just format` and `just format-check` |
| Ruby + Bundler | 3.3+ (for Fastlane, release builds only) |

## Quick start

```bash
git clone <repo>
cd moolah-native
just generate   # creates Moolah.xcodeproj from project.yml
just open       # opens in Xcode
```

> **Tip:** Re-run `just generate` after editing `project.yml`. Never edit
> `Moolah.xcodeproj/project.pbxproj` directly.

## Building & Running

```bash
just run-mac     # build and launch the macOS app directly
just build-mac   # build for macOS without launching (ad-hoc signed, no certificate needed)
just build-ios   # build for iPhone 17 Pro simulator
```

`just run-mac` writes its build products to `.build/` in the repo root so they don't
mix with Xcode's DerivedData, then opens the resulting `.app` bundle directly.

To build and run from Xcode: select the **Moolah** scheme and your destination, then
press **Run** (⌘R).

| Target | Destination |
|---|---|
| `Moolah_iOS` | iPhone 17 Pro simulator (iOS 26) |
| `Moolah_macOS` | My Mac |

## Running Tests

```bash
just test
```

Runs the full test suite on both iPhone 17 Pro simulator and macOS. All feature and
domain tests use `InMemoryBackend` — no network connection or server account is
needed. See [`scripts/test.sh`](scripts/test.sh) for the platform-specific details.

To run one platform manually:

```bash
xcodebuild test -scheme Moolah -destination "platform=iOS Simulator,name=iPhone 17 Pro"
xcodebuild test -scheme Moolah -destination "platform=macOS"
```

## Sign-in with the REST backend

The app connects to **`https://moolah.rocks/api/`** and authenticates via Google
OAuth. Sign-in opens an in-app browser (`ASWebAuthenticationSession`) — the user
never leaves the app.

### Sign-in flow

1. Launch the app.
2. Tap **Sign in with Google** on the Welcome screen.
3. An in-app browser opens the server's Google sign-in page.
4. Sign in with your Google account.
5. **With server update applied** (see below): the browser closes automatically and
   the app shows your name in the toolbar.
6. **Without server update**: after signing in you'll see the moolah.rocks web app
   inside the browser; tap **Cancel** to return to the native app — you'll be signed
   in. The UX is slightly rough but fully functional.

### Configuring smooth in-app sign-in (`moolah://auth/callback`)

For the browser to close automatically after sign-in, the server must redirect to
`moolah://auth/callback` instead of `/` when the OAuth flow was initiated by the
native app. The native app passes `?_native=1` in the initial OAuth request; Bell
preserves this parameter through the Google OAuth dance.

**Server change required:** see [`prompts/moolah-server-native-auth.md`](prompts/moolah-server-native-auth.md)
for the exact one-file change to `src/handlers/auth/googleLogin.js`. No Google
Cloud Console configuration changes are needed.

**`moolah://` URL scheme** is already registered in `App/Info-iOS.plist` and
`App/Info-macOS.plist`. No additional Xcode configuration is required.

## Project Structure

```
moolah-native/
├── App/                    # Entry point (MoolahApp.swift), composition root
├── Domain/
│   ├── Models/             # Plain Swift structs: UserProfile, Account, Transaction, …
│   └── Repositories/       # Protocol definitions only — no backend imports
├── Backends/
│   ├── CloudKit/           # iCloud/CloudKit backend (SwiftData, local-first sync)
│   └── Remote/             # REST API backend (URLSession, DTOs, concrete repos)
│       ├── APIClient/      # URLSession wrapper with HTTP error mapping
│       └── Auth/           # RemoteAuthProvider (Google OAuth via ASWebAuthenticationSession)
├── Features/               # One folder per screen/feature
│   ├── Auth/               # AuthStore, AppRootView, WelcomeView, UserMenuView
│   └── …
├── Shared/
│   ├── Components/         # Reusable SwiftUI views
│   └── Extensions/
├── MoolahTests/
│   ├── Domain/             # Pure logic and model tests
│   ├── Features/           # Store tests using InMemoryBackend
│   ├── Support/
│   │   ├── InMemoryBackend/ # In-memory BackendProvider for tests
│   │   └── Fixtures/        # JSON fixture files
│   └── UI/                 # Snapshot and XCUITest
├── fastlane/               # Fastlane config for TestFlight/App Store builds
├── prompts/                # Prompts for related server-side changes
├── plans/                  # Planning documents and feature specs
├── justfile                # Common dev tasks (just build-mac, just test, …)
├── project.yml             # XcodeGen spec — edit this, not the .xcodeproj
├── .github/workflows/      # CI, TestFlight, and monthly auto-tag workflows
└── scripts/
    └── test.sh             # Runs tests on both platforms
```

## Architecture

The app uses a **repository pattern** to decouple features from any specific backend.

```
Views / Stores  →  Repository protocols  →  Backend implementations
                   (Domain layer)            CloudKit (SwiftData + iCloud sync)
                                             Remote (URLSession + cookies)
```

- **Domain models** (`UserProfile`, `Account`, `Transaction`, etc.) are plain Swift
  structs in the `Domain` module. Features only ever see these types.
- **Repository protocols** (`AuthProvider`, `AccountRepository`, ...) express
  operations in domain terms — no networking or persistence imports.
- **`BackendProvider`** is the single injection point via `@Environment`. Swap the
  backend at the composition root (`MoolahApp.swift`) without touching feature code.
- **`InMemoryBackend`** (test target only) is a full in-memory implementation used in
  all tests. It is never compiled into the app binary.

Users choose their backend when creating a profile: iCloud (CloudKit), Moolah server,
or a custom server URL.

## Code Signing

- **Local development:** iOS targets are unsigned (simulators don't require it). macOS
  targets are ad-hoc signed (`CODE_SIGN_IDENTITY="-"`) with Hardened Runtime disabled.
- **Distribution builds:** Fastlane Match manages certificates and provisioning profiles
  via a private git repo. Entitlements (App Sandbox, CloudKit) are applied during
  distribution builds only.

## Release & TestFlight

Releases are automated via GitHub Actions and Fastlane:

- **Tag push** (`v1.0.0`) triggers `.github/workflows/testflight.yml` which builds and
  uploads to TestFlight.
- **Monthly auto-tag** (`.github/workflows/monthly-tag.yml`) creates a tag on the 1st
  of each month to keep TestFlight builds within the 90-day expiry.
- **Manual trigger** via `workflow_dispatch` on either workflow.

```bash
just bump-version 1.2.0   # update MARKETING_VERSION in project.yml
git tag v1.2.0 && git push origin v1.2.0   # triggers TestFlight build
```

Local shortcuts:

```bash
just certificates   # sync signing certs via Fastlane Match
just testflight     # build and upload to TestFlight locally
```

See [`plans/IOS_RELEASE_AUTOMATION_PLAN.md`](plans/IOS_RELEASE_AUTOMATION_PLAN.md) for
the full setup guide including Apple Developer account configuration and GitHub secrets.
