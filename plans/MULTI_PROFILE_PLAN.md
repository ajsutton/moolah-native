# Multi-Profile Support Implementation Plan

## Context

The app currently supports a single hardcoded remote backend (`http://localhost:8080/api/`). Users need to connect to multiple Moolah servers (or future iCloud backends) with separate credentials. The multi-profile layer sits *above* the existing architecture — stores, repositories, and feature views require zero changes.

**Key decisions:**
- "Profile" naming (avoids collision with bank "Account")
- Profiles viewed independently, no cross-profile aggregation
- No background refresh for inactive profiles
- Fresh install defaults to moolah.rocks with custom server option
- Single-active profile on both platforms for now; data structure supports future macOS multi-window

## Phase 1: Profile Domain Model

**New file:** `Domain/Models/Profile.swift`

```swift
enum BackendType: String, Codable, Sendable {
    case remote
    // Future: case iCloud
}

struct Profile: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var label: String
    var backendType: BackendType
    var serverURL: URL
    var cachedUserName: String?
    let createdAt: Date
}
```

**New test:** `MoolahTests/Domain/ProfileTests.swift`
- JSON round-trip, equality, defaults

## Phase 2: ProfileStore

**New file:** `Features/Profiles/ProfileStore.swift`

```swift
@Observable @MainActor
final class ProfileStore {
    private(set) var profiles: [Profile]
    private(set) var activeProfileID: UUID?
    var activeProfile: Profile? { ... }
    var hasProfiles: Bool { ... }

    init(defaults: UserDefaults = .standard)  // injectable for tests

    func addProfile(_ profile: Profile)       // sets active if first
    func removeProfile(_ id: UUID)            // cleans up keychain cookies too
    func setActiveProfile(_ id: UUID)
    func updateProfile(_ profile: Profile)
}
```

Persists to UserDefaults as JSON. On `removeProfile`, also clears that profile's `CookieKeychain` entry to avoid keychain accumulation.

**New test:** `MoolahTests/Features/ProfileStoreTests.swift`
- Add/remove/switch/update, persistence round-trip, keychain cleanup on remove

## Phase 3: Cookie Isolation (Backends)

*Independent of Phase 2 — can be done in parallel.*

### 3a: APIClient — use session's cookie storage for logging

**File:** `Backends/Remote/APIClient/APIClient.swift`

Change hardcoded `HTTPCookieStorage.shared.cookies(for:)` (line 22) to `session.configuration.httpCookieStorage?.cookies(for:)`.

### 3b: RemoteAuthProvider — accept HTTPCookieStorage parameter

**File:** `Backends/Remote/Auth/RemoteAuthProvider.swift`

Add `cookieStorage: HTTPCookieStorage = .shared` to init. Replace all 3 uses of `HTTPCookieStorage.shared` in `saveCookies()`, `restoreCookiesIfNeeded()`, `clearCookieStorage()` with the stored property.

### 3c: RemoteBackend — accept URLSession + CookieKeychain

**File:** `Backends/Remote/RemoteBackend.swift`

```swift
init(baseURL: URL, session: URLSession = .shared, cookieKeychain: CookieKeychain = CookieKeychain()) {
    let client = APIClient(baseURL: baseURL, session: session)
    let cookieStorage = session.configuration.httpCookieStorage ?? .shared
    auth = RemoteAuthProvider(client: client, cookieKeychain: cookieKeychain, cookieStorage: cookieStorage)
    // ... remaining repositories unchanged
}
```

All existing callers continue to work — defaults match current behavior.

## Phase 4: ProfileSession

**New file:** `App/ProfileSession.swift`

```swift
@Observable @MainActor
final class ProfileSession: Identifiable {
    let profile: Profile
    let backend: BackendProvider
    let authStore: AuthStore
    let accountStore: AccountStore
    let transactionStore: TransactionStore
    let categoryStore: CategoryStore
    let earmarkStore: EarmarkStore
    let analysisStore: AnalysisStore
    let investmentStore: InvestmentStore

    nonisolated var id: UUID { profile.id }

    init(profile: Profile) {
        // Creates isolated URLSession with its own HTTPCookieStorage()
        // Creates CookieKeychain keyed by profile.id.uuidString
        // Creates RemoteBackend with both
        // Creates all stores, wires transactionStore.onMutate
    }
}
```

Each profile gets:
- Its own `URLSession` with a fresh `HTTPCookieStorage()` instance
- Its own `CookieKeychain(account: profile.id.uuidString)` for persistent cookie storage

**New test:** `MoolahTests/App/ProfileSessionTests.swift`
- Session creates non-nil stores
- Two sessions for different profiles have independent cookie keystores
- `onMutate` wiring works

## Phase 5: MoolahApp Rewrite

**Modified file:** `App/MoolahApp.swift`

Replace hardcoded single-backend with ProfileStore + ProfileSession:

```swift
@main @MainActor
struct MoolahApp: App {
    private let profileStore: ProfileStore
    @State private var activeSession: ProfileSession?

    var body: some Scene {
        WindowGroup {
            ProfileRootView(activeSession: $activeSession)
                .environment(profileStore)
        }
    }
}
```

**New file:** `App/ProfileRootView.swift`

Routes between states:
- No profiles → `ProfileSetupView`
- Has active session → `SessionRootView(session:)`
- Loading → `ProgressView`

Watches `profileStore.activeProfileID` via `onChange` to create/swap sessions.

**New file:** `App/SessionRootView.swift`

Injects all 7 stores from the session into the environment, then shows `AppRootView()`:

```swift
AppRootView()
    .id(session.id)  // forces full rebuild on profile switch
    .environment(session.authStore)
    .environment(session.accountStore)
    // ... all 7 stores
```

The `.id(session.id)` is critical — it forces SwiftUI to destroy and recreate the entire view hierarchy when profiles change, preventing stale state leaks.

**Unchanged:** `AppRootView`, `ContentView`, all feature views. They still read stores from `@Environment` exactly as before.

## Phase 6: First-Run Experience

**New file:** `Features/Profiles/Views/ProfileSetupView.swift`

Shown when `profileStore.hasProfiles == false`:
- "Moolah" branding (matches existing WelcomeView aesthetic)
- Primary CTA: **"Sign in to Moolah"** → creates profile with `https://moolah.rocks/api/`
- Secondary link: **"Use a custom server"** → expands to show URL + label fields
- Creating a profile triggers session creation via `onChange` in MoolahApp, which flows into `AppRootView` → `WelcomeView` → Google OAuth

## Phase 7: Profile Switcher UI

**Modified file:** `Features/Auth/UserMenuView.swift`

Add profile switching to the existing user menu (between user name and Sign Out):

```
[Ada Lovelace]           ← existing
─────────────
  ✓ Moolah               ← profile list with checkmark on active
    Work Server
─────────────
  Add Profile...          ← opens ProfileSetupView as sheet
─────────────
  Sign Out                ← existing (signs out of current profile's auth)
```

This keeps discovery high without adding a separate toolbar item.

**New file:** `Features/Profiles/Views/AddProfileView.swift`

Sheet for adding a profile (reuses the server picker UI from ProfileSetupView, extracted as shared component or inline).

## Phase 8: Cache User Name on Sign-In

**Modified file:** `App/SessionRootView.swift` or `App/ProfileRootView.swift`

When `authStore.state` transitions to `.signedIn(user)`, update the profile's cached display name:

```swift
.onChange(of: session.authStore.state) { _, newState in
    if case .signedIn(let user) = newState {
        var updated = session.profile
        updated.cachedUserName = "\(user.givenName) \(user.familyName)"
        profileStore.updateProfile(updated)
    }
}
```

This lets the profile switcher show names even before the session is loaded.

## Phase Dependency Graph

```
Phase 1 (Profile model)
    ├── Phase 2 (ProfileStore)
    │       │
    └── Phase 3 (Cookie isolation)  ← parallel with Phase 2
            │
        Phase 4 (ProfileSession)    ← depends on 1+2+3
            │
        Phase 5 (MoolahApp rewrite) ← depends on 4
            │
        ┌───┴───┐
  Phase 6    Phase 7               ← parallel
  (Setup)    (Switcher)
        └───┬───┘
        Phase 8 (Cache name)
```

## Files Changed Summary

| Action | File |
|--------|------|
| **New** | `Domain/Models/Profile.swift` |
| **New** | `Features/Profiles/ProfileStore.swift` |
| **New** | `App/ProfileSession.swift` |
| **New** | `App/ProfileRootView.swift` |
| **New** | `App/SessionRootView.swift` |
| **New** | `Features/Profiles/Views/ProfileSetupView.swift` |
| **New** | `Features/Profiles/Views/AddProfileView.swift` |
| **New** | `MoolahTests/Domain/ProfileTests.swift` |
| **New** | `MoolahTests/Features/ProfileStoreTests.swift` |
| **New** | `MoolahTests/App/ProfileSessionTests.swift` |
| **Edit** | `Backends/Remote/APIClient/APIClient.swift` (cookie logging) |
| **Edit** | `Backends/Remote/Auth/RemoteAuthProvider.swift` (cookie storage param) |
| **Edit** | `Backends/Remote/RemoteBackend.swift` (session + keychain params) |
| **Edit** | `App/MoolahApp.swift` (composition root rewrite) |
| **Edit** | `Features/Auth/UserMenuView.swift` (profile switcher in menu) |

## What Does NOT Change

- All domain models, repository protocols, remote repository implementations
- `BackendProvider` protocol, `InMemoryBackend`
- All 7 stores (`AuthStore`, `AccountStore`, etc.)
- `AppRootView`, `ContentView`, `WelcomeView`, all feature views
- `project.yml` (new files auto-included by existing path globs)

## Verification

After each phase:
1. `just test` — all existing tests pass, new tests pass
2. `mcp__xcode__XcodeListNavigatorIssues` with severity "warning" — no new warnings
3. After Phase 5+6: manual test fresh launch → setup → sign in → content loads
4. After Phase 7: manual test add second profile → switch between them → data isolated
5. After Phase 8: sign in → force quit → relaunch → profile switcher shows cached name

## Future: macOS Multi-Window

`ProfileSession` is `Identifiable` by `profile.id`. When ready:
- `WindowGroup(for: Profile.ID.self)` opens a window per profile
- Each window creates its own `ProfileSession`
- `ProfileStore` remains shared across windows
- `SessionRootView` already accepts a session parameter — works naturally
