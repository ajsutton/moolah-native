# Claude Code Instructions — moolah-native

## Build & Test

Always use the test script — it handles sandvault and platform differences:

```bash
bash scripts/test.sh
```

After changing `project.yml`, regenerate the Xcode project before building or testing:

```bash
xcodegen generate
```

Never edit `Moolah.xcodeproj/project.pbxproj` directly. All project configuration lives in `project.yml`.

## Architecture Rules

### Domain layer is strictly isolated
- `Domain/Models/` and `Domain/Repositories/` must never import `SwiftUI`, `SwiftData`, `URLSession`, or any backend module.
- Repository protocols express operations using domain model types only.

### Features only talk to repository protocols
- Feature stores (`@Observable` classes) receive repository protocols via `@Environment(BackendProvider.self)`.
- No feature file may import `Backends/` or reference `Remote*` types directly.

### InMemoryBackend is the test and preview backend
- All feature tests use `InMemoryBackend`, never `RemoteBackend`.
- All SwiftUI Previews use `InMemoryBackend`.
- `InMemoryBackend` lives in `MoolahTests/Support/InMemoryBackend/` — it is a test-only target, not shipped in the app.
- **Every `InMemoryBackend` method must be verified against `moolah-server` source before implementation.** Read the corresponding route/controller in `../moolah-server/src/` to confirm filtering semantics, sort order, pagination contract, and computed values are exactly compatible.

### Adding a new backend
- Implement `BackendProvider` and all repository protocols in a new `Backends/<Name>/` folder.
- Wire it up in `App/` at the composition root.
- No other code changes required.

## Testing Conventions

- Write the test file before the implementation file (TDD).
- Every repository protocol has a **contract test suite** in `MoolahTests/Domain/`. Both `InMemoryBackend` and `RemoteBackend` run this same suite to prove substitutability.
- Remote backend tests use `URLProtocol` stubs against fixture JSON in `MoolahTests/Support/Fixtures/`.
- Test targets: `MoolahTests_iOS` (simulator) and `MoolahTests_macOS` (native).

## Platform Notes

### Sandvault
`scripts/test.sh` detects `SV_SESSION_ID` and applies workarounds automatically:
- `SWIFTPM_DISABLE_SANDBOX=1` and `SWIFT_BUILD_USE_SANDBOX=0` are always set.
- On macOS inside sandvault, `IDEInstallLocalMacService` (XPC) is blocked, so the script uses `build-for-testing` + `xcrun xctest` instead of `xcodebuild test`.

### Code signing
- iOS targets: `CODE_SIGNING_ALLOWED=NO` — simulators don't need signing.
- macOS targets: `CODE_SIGN_IDENTITY="-"` (ad-hoc), `ENABLE_HARDENED_RUNTIME=NO` — satisfies Gatekeeper locally without a developer certificate.
- Never set `CODE_SIGNING_ALLOWED=NO` on a macOS target — Gatekeeper will block the unsigned binary.

### Xcode project generation
The project targets iOS 26 and macOS 26. The simulator is `iPhone 17 Pro` (iOS 26 does not include iPhone 16 Pro).

## Swift 6

The project uses `SWIFT_VERSION=6.0`. All new code must satisfy strict concurrency:
- Mark types `@MainActor` when they own UI-bound state.
- Use `Sendable` on all types that cross actor boundaries.
- Prefer `async/await` over callbacks or completion handlers.
