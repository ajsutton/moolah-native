# Moolah — Native iOS/macOS App

A universal personal finance app for iPhone and Mac. Tracks accounts, transactions,
categories, earmarks (savings goals), scheduled payments, and provides analysis and
reporting. Connects to the [ajsutton/moolah-server](https://github.com/ajsutton/moolah-server)
REST API at `https://moolah.rocks/api/`.

## Requirements

| Tool | Version |
|---|---|
| Xcode | 26+ |
| iOS deployment target | 26+ |
| macOS deployment target | 26+ |
| XcodeGen | Latest (`brew install xcodegen`) |
| just | Latest (`brew install just`) |

## Quick start

```bash
git clone <repo>
cd moolah-native
just generate   # creates Moolah.xcodeproj from project.yml
just open       # opens in Xcode
```

> **Tip:** Re-run `just generate` after editing `project.yml`. Never edit
> `Moolah.xcodeproj/project.pbxproj` directly.

## Building

```bash
just build-mac   # build for macOS (ad-hoc signed, no certificate needed)
just build-ios   # build for iPhone 17 Pro simulator
```

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

**`moolah://` URL scheme** is already registered in `App/Info.plist`. No additional
Xcode configuration is required.

## Project Structure

```
moolah-native/
├── App/                    # Entry point (MoolahApp.swift), composition root
├── Domain/
│   ├── Models/             # Plain Swift structs: UserProfile, Account, Transaction, …
│   └── Repositories/       # Protocol definitions only — no backend imports
├── Backends/
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
├── prompts/                # Prompts for related server-side changes
├── justfile                # Common dev tasks (just build-mac, just test, …)
├── project.yml             # XcodeGen spec — edit this, not the .xcodeproj
└── scripts/
    └── test.sh             # Runs tests on both platforms
```

## Architecture

The app uses a **repository pattern** to decouple features from any specific backend.
The current backend is the Moolah REST API; a future iCloud/CloudKit backend can be
substituted without touching any feature code.

```
Views / Stores  →  Repository protocols  →  Backend implementations
                   (Domain layer)            Remote (URLSession + cookies)
                                             CloudKit (future)
```

- **Domain models** (`UserProfile`, `Account`, `Transaction`, etc.) are plain Swift
  structs in the `Domain` module. Features only ever see these types.
- **Repository protocols** (`AuthProvider`, `AccountRepository`, …) express
  operations in domain terms — no networking or persistence imports.
- **`BackendProvider`** is the single injection point via `@Environment`. Swap the
  backend at the composition root (`MoolahApp.swift`) without touching feature code.
- **`InMemoryBackend`** (test target only) is a full in-memory implementation used in
  all tests. It is never compiled into the app binary.

See [`NATIVE_APP_PLAN.md`](NATIVE_APP_PLAN.md) for the full incremental implementation plan.

## Code Signing

- **iOS targets:** unsigned (simulators don't require it).
- **macOS targets:** ad-hoc signed (`CODE_SIGN_IDENTITY="-"`) with Hardened Runtime
  disabled — satisfies Gatekeeper for local development without a paid developer
  certificate.
