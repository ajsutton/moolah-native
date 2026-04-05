# Moolah — Native iOS/macOS App

A universal personal finance app for iPhone and Mac. Tracks accounts, transactions, categories, earmarks (savings goals), scheduled payments, and provides analysis and reporting. Connects to the [ajsutton/moolah-server](https://github.com/ajsutton/moolah-server) REST API.

## Requirements

| Tool | Version |
|---|---|
| Xcode | 26+ |
| iOS deployment target | 26+ |
| macOS deployment target | 26+ |
| XcodeGen | Latest (`brew install xcodegen`) |

## Setup

```bash
git clone <repo>
cd moolah-native
xcodegen generate      # creates Moolah.xcodeproj from project.yml
open Moolah.xcodeproj
```

> **Note:** `Moolah.xcodeproj` is generated from `project.yml` and is committed to the repo. Re-run `xcodegen generate` after editing `project.yml`.

## Running Tests

```bash
scripts/test.sh
```

Runs the full test suite on both iPhone 17 Pro simulator and macOS. The script handles sandvault and standard environments automatically — see [`scripts/test.sh`](scripts/test.sh) for details.

To run a single platform manually:

```bash
# iOS Simulator
xcodebuild test -scheme Moolah -destination "platform=iOS Simulator,name=iPhone 17 Pro"

# macOS
xcodebuild test -scheme Moolah -destination "platform=macOS"
```

## Project Structure

```
moolah-native/
├── App/                    # Entry point (MoolahApp.swift, ContentView.swift)
├── Domain/
│   ├── Models/             # Plain Swift structs: Account, Transaction, …
│   └── Repositories/       # Protocol definitions only — no backend imports
├── Backends/
│   └── Remote/             # REST API backend (URLSession, DTOs, concrete repos)
├── Features/               # One folder per screen/feature
│   ├── Auth/
│   ├── Accounts/
│   ├── Transactions/
│   ├── Categories/
│   ├── Earmarks/
│   ├── Upcoming/
│   ├── Analysis/
│   ├── Reports/
│   └── Investments/
├── Shared/
│   ├── Components/         # Reusable SwiftUI views
│   └── Extensions/
├── MoolahTests/
│   ├── Domain/             # Pure logic and model tests
│   ├── Remote/             # REST backend tests (URLProtocol stubs)
│   ├── Features/           # Store tests using InMemoryBackend
│   ├── Support/
│   │   ├── InMemoryBackend/ # In-memory BackendProvider for tests & Previews
│   │   └── Fixtures/        # JSON fixture files
│   └── UI/                 # Snapshot and XCUITest
├── project.yml             # XcodeGen spec — edit this, not the .xcodeproj
└── scripts/
    └── test.sh             # Runs tests on both platforms
```

## Architecture

The app uses a **repository pattern** to decouple all features from any specific backend. The current backend is the Moolah REST API; a future iCloud/CloudKit backend can be substituted without touching any feature code.

```
Views / Stores  →  Repository protocols  →  Backend implementations
                   (Domain layer)            Remote (URLSession)
                                             CloudKit (future)
```

- **Domain models** (`Account`, `Transaction`, etc.) are plain Swift structs. Features only ever see these types.
- **Repository protocols** express operations in domain terms. They have no networking or persistence imports.
- **`BackendProvider`** is the single injection point, passed via `@Environment`. Swap the backend by providing a different `BackendProvider` at the composition root.
- **`InMemoryBackend`** is a full in-memory implementation of every protocol used in all tests and SwiftUI Previews.

See [`NATIVE_APP_PLAN.md`](../moolah/NATIVE_APP_PLAN.md) for the full implementation plan.

## Code Signing

- **iOS targets:** unsigned (simulators don't require it)
- **macOS targets:** ad-hoc signed (`CODE_SIGN_IDENTITY="-"`) with Hardened Runtime disabled — satisfies Gatekeeper for local development without a paid developer certificate
