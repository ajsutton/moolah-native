# macOS Multi-Window Profile Support

## Context

The multi-profile system is fully implemented (see `plans/completed/MULTI_PROFILE_PLAN.md`). Currently both platforms use a single-active-profile model: one `ProfileSession` at a time, switching replaces it. The architecture was designed to support macOS multi-window — `ProfileSession` is `Identifiable`, `SessionRootView` accepts a session parameter, and `ProfileStore` is shared.

This plan adds macOS multi-window support: each profile opens in its own window. iOS remains single-profile with in-place switching.

## Design Decisions

- **macOS**: Each profile opens in a separate window via `WindowGroup(for: Profile.ID.self)`. No two windows may show the same profile.
- **iOS**: Unchanged. Single active profile, switching via `UserMenuView`.
- **Window restoration**: SwiftUI's `WindowGroup(for:)` automatically restores open windows on relaunch.
- **Close behavior**: Closing a window does not sign out. Closing the last window quits the app (default macOS behavior).
- **File menu**: "Open Profile" items open windows (or bring existing to front). "Sign Out" moves from user menu to File menu on macOS.
- **User menu (macOS)**: Shows profile label instead of profile switcher. No sign-out button (moved to File menu).
- **User menu (iOS)**: Unchanged.
- **Settings**: All profiles show live auth status since any profile could have an open session. `SettingsView` looks up sessions from the shared `SessionManager`.

## Architecture

### SessionManager

New `@Observable @MainActor` class that owns the mapping from `Profile.ID` to `ProfileSession`. Replaces the single `@State var activeSession: ProfileSession?` in `MoolahApp`.

**File:** `App/SessionManager.swift`

```swift
@Observable
@MainActor
final class SessionManager {
    private(set) var sessions: [UUID: ProfileSession] = [:]

    func session(for profile: Profile) -> ProfileSession {
        if let existing = sessions[profile.id] { return existing }
        let session = ProfileSession(profile: profile)
        sessions[profile.id] = session
        return session
    }

    func removeSession(for profileID: UUID) {
        sessions.removeValue(forKey: profileID)
    }

    func rebuildSession(for profile: Profile) {
        sessions[profile.id] = ProfileSession(profile: profile)
    }
}
```

**Why a separate class instead of a Dictionary in MoolahApp?**
- Multiple windows need to share session instances. SwiftUI creates a new view per window from `WindowGroup(for:)`, but they all need to find the same `ProfileSession` for a given profile.
- `SettingsView` needs access to sessions for any profile to show live auth status.
- Injected via `.environment(sessionManager)` at the app level.

### MoolahApp Scene Structure

**File:** `App/MoolahApp.swift`

The app defines two scene types:

```swift
@main @MainActor
struct MoolahApp: App {
    @State private var profileStore = ProfileStore(validator: RemoteServerValidator())
    @State private var sessionManager = SessionManager()

    var body: some Scene {
        // macOS: profile windows; iOS: single-profile window
        #if os(macOS)
        WindowGroup(for: Profile.ID.self) { $profileID in
            ProfileWindowView(profileID: profileID)
                .environment(profileStore)
                .environment(sessionManager)
        }
        .commands {
            ProfileCommands(profileStore: profileStore)
            NewTransactionCommands()
            NewEarmarkCommands()
            RefreshCommands()
            ShowHiddenCommands()
        }
        #else
        WindowGroup {
            ProfileRootView(activeSession: $activeSession)
                .environment(profileStore)
        }
        .commands {
            NewTransactionCommands()
            NewEarmarkCommands()
            RefreshCommands()
            ShowHiddenCommands()
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(profileStore)
                .environment(sessionManager)
        }
        #endif
    }
}
```

**iOS stays exactly as-is.** The `#if os(macOS)` / `#else` split keeps iOS code unchanged.

On macOS, the `ModelContainer` setup can be removed if it's only used for the empty schema (verify during implementation).

### ProfileWindowView (macOS only)

**New file:** `App/ProfileWindowView.swift`

Each macOS window receives a `Profile.ID?` from the `WindowGroup(for:)`. This view resolves it to a session:

```swift
struct ProfileWindowView: View {
    let profileID: Profile.ID?
    @Environment(ProfileStore.self) private var profileStore
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        if let profileID,
           let profile = profileStore.profiles.first(where: { $0.id == profileID }) {
            let session = sessionManager.session(for: profile)
            SessionRootView(session: session)
                .environment(profileStore)
        } else if !profileStore.hasProfiles {
            ProfileSetupView()
        } else {
            // Profile was deleted — window should close or show placeholder
            ContentUnavailableView(
                "Profile Not Found",
                systemImage: "person.crop.circle.badge.xmark",
                description: Text("This profile has been removed.")
            )
        }
    }
}
```

**User name caching:** The `onChange(of: authStore.state)` logic currently in `ProfileRootView` needs to move into `ProfileWindowView` (or `SessionRootView`) so that each window caches its profile's user name on sign-in.

**URL change handling:** The `onChange(of: profile.resolvedServerURL)` logic currently in `ProfileRootView` needs to call `sessionManager.rebuildSession(for:)` when a profile's URL is edited in Settings.

### Opening Windows and Preventing Duplicates

**File:** `Features/Profiles/ProfileCommands.swift`

The File menu uses `@Environment(\.openWindow)` to open profile windows:

```swift
struct ProfileCommands: Commands {
    let profileStore: ProfileStore

    var body: some Commands {
        CommandGroup(before: .saveItem) {
            Menu("Open Profile") {
                ForEach(profileStore.profiles) { profile in
                    Button(profile.label) {
                        openWindow(value: profile.id)
                    }
                }

                if profileStore.profiles.isEmpty {
                    Text("No Profiles")
                }

                Divider()
                SettingsLink { Text("Manage Profiles...") }
            }

            Divider()
        }

        // Sign Out for the focused window's profile
        CommandGroup(replacing: .appTermination) { ... }
    }
}
```

**Duplicate prevention:** `WindowGroup(for: Profile.ID.self)` with `openWindow(value:)` — SwiftUI should bring an existing window with that value to front rather than opening a duplicate. If SwiftUI doesn't do this automatically, we can track open profile IDs in `SessionManager` and use `NSApp.windows` to find and activate the existing window. This needs to be verified during implementation.

### Sign Out in File Menu (macOS)

Sign Out moves from `UserMenuView` to `ProfileCommands` on macOS. It needs access to the focused window's session. Use `@FocusedValue` to propagate the current window's `AuthStore`:

**New focused value key:**

```swift
struct FocusedAuthStoreKey: FocusedValueKey {
    typealias Value = AuthStore
}

extension FocusedValues {
    var authStore: AuthStore? {
        get { self[FocusedAuthStoreKey.self] }
        set { self[FocusedAuthStoreKey.self] = newValue }
    }
}
```

`SessionRootView` (or `ProfileWindowView`) publishes this:

```swift
.focusedValue(\.authStore, session.authStore)
```

`ProfileCommands` consumes it:

```swift
@FocusedValue(\.authStore) private var authStore

// In body:
Button("Sign Out", role: .destructive) {
    if let authStore {
        Task { await authStore.signOut() }
    }
}
.disabled(authStore == nil)
```

### UserMenuView Changes (macOS)

On macOS, the user menu simplifies:
- **Remove**: Profile switcher section, Sign Out button
- **Add**: Profile label display
- **Keep**: User name, avatar

```swift
struct UserMenuView: View {
    let user: UserProfile
    @Environment(ProfileSession.self) private var session

    var body: some View {
        #if os(macOS)
        macOSUserMenu
        #else
        // iOS: unchanged, full menu with profile switcher and sign out
        iOSUserMenu
        #endif
    }

    #if os(macOS)
    private var macOSUserMenu: some View {
        HStack(spacing: 6) {
            avatarView
            VStack(alignment: .leading, spacing: 0) {
                Text(user.givenName)
                    .font(.subheadline)
                Text(session.profile.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: avatarSize)
    }
    #endif
}
```

On macOS the user menu becomes a non-interactive label (no Menu wrapper) showing the avatar, user name, and profile label. Sign out is in the File menu. Profile switching is via File > Open Profile.

### SettingsView Changes

Currently `SettingsView` receives `activeSession: ProfileSession?` and can only show live auth status for the single active profile. With multi-window, any profile might have an active session.

**Change:** Replace `activeSession` parameter with `@Environment(SessionManager.self)`. Look up the session for each profile:

```swift
private func profileDetailView(for profile: Profile) -> some View {
    let authStore = sessionManager.sessions[profile.id]?.authStore

    switch profile.backendType {
    case .moolah:
        MoolahProfileDetailView(profile: profile, authStore: authStore)
    case .remote:
        CustomServerProfileDetailView(profile: profile, authStore: authStore)
    }
}
```

**ProfileAuthStatusView offline message change:** Currently says "Switch to this profile to sign in". For macOS, change to "Open this profile to sign in" (or just "Open profile to sign in"). Keep the iOS wording as-is.

### ProfileRootView (iOS only)

`ProfileRootView` becomes iOS-only. Its role doesn't change — it manages the single `activeSession` binding, watches `profileStore.activeProfileID`, and routes between setup/session/loading states.

The macOS equivalent is `ProfileWindowView` which gets its profile ID from the `WindowGroup(for:)` binding.

### First-Run Flow (macOS)

On first launch with no profiles, `WindowGroup(for: Profile.ID.self)` opens with a `nil` profile ID. `ProfileWindowView` detects `!profileStore.hasProfiles` and shows `ProfileSetupView`.

After the user creates their first profile, the view should:
1. Open a window for the new profile via `openWindow(value: profile.id)`
2. The setup window transitions naturally since the profile store now has profiles

This may need `@Environment(\.openWindow)` in `ProfileSetupView` on macOS, or the `ProfileWindowView` can react to the profile being added and update its binding.

### Window Title

Each profile window should show the profile label as its window title. Add `.navigationTitle(session.profile.label)` in `ProfileWindowView` or `SessionRootView` on macOS.

## Phase Plan

### Phase 1: SessionManager

**New file:** `App/SessionManager.swift`
**New test:** `MoolahTests/App/SessionManagerTests.swift`

- Create `SessionManager` class with session lifecycle methods
- Tests: session creation, reuse, removal, rebuild

### Phase 2: FocusedValue for AuthStore

**New file:** `Features/Auth/FocusedAuthStoreKey.swift`

- Add `FocusedAuthStoreKey` and `FocusedValues` extension
- Wire `.focusedValue(\.authStore, ...)` in `SessionRootView`

### Phase 3: MoolahApp + ProfileWindowView (macOS)

**Modified:** `App/MoolahApp.swift`
**New file:** `App/ProfileWindowView.swift`

- Split MoolahApp scene body by platform
- macOS: `WindowGroup(for: Profile.ID.self)` + `ProfileWindowView`
- iOS: unchanged `WindowGroup` + `ProfileRootView`
- Move user-name caching and URL-change handling into `ProfileWindowView`
- Add `.navigationTitle` for window title

### Phase 4: ProfileCommands Update

**Modified:** `Features/Profiles/ProfileCommands.swift`

- Change toggle items to `openWindow(value: profile.id)` buttons
- Add Sign Out command using `@FocusedValue(\.authStore)`
- Verify duplicate window prevention (may need NSApp fallback)

### Phase 5: UserMenuView (macOS changes)

**Modified:** `Features/Auth/UserMenuView.swift`

- macOS: replace Menu with static label showing avatar + name + profile label
- iOS: unchanged

### Phase 6: SettingsView Update

**Modified:** `Features/Settings/SettingsView.swift`

- Replace `activeSession` parameter with `@Environment(SessionManager.self)`
- Look up per-profile sessions for live auth status
- Update "Switch to this profile" text on macOS

### Phase 7: ProfileRootView Scoping

**Modified:** `App/ProfileRootView.swift`

- Wrap in `#if os(iOS)` / `#endif` (or leave cross-platform if it's still useful as-is)
- No logic changes needed for iOS

### Phase 8: Integration Testing

- Manual test: open multiple profile windows on macOS
- Verify window restoration on relaunch
- Verify duplicate prevention (File > Open Profile for already-open profile)
- Verify closing last window quits app
- Verify Settings shows live auth for all open profiles
- Verify iOS is completely unchanged
- Run `just test` to confirm no regressions

## Phase Dependency Graph

```
Phase 1 (SessionManager)
    │
Phase 2 (FocusedValue)      ← parallel with Phase 1
    │
Phase 3 (MoolahApp + ProfileWindowView)  ← depends on 1
    │
    ├── Phase 4 (ProfileCommands)         ← depends on 2+3
    ├── Phase 5 (UserMenuView)            ← depends on 3
    ├── Phase 6 (SettingsView)            ← depends on 1+3
    └── Phase 7 (ProfileRootView)         ← depends on 3
         │
     Phase 8 (Integration Testing)        ← depends on all
```

## Files Changed Summary

| Action | File |
|--------|------|
| **New** | `App/SessionManager.swift` |
| **New** | `App/ProfileWindowView.swift` |
| **New** | `Features/Auth/FocusedAuthStoreKey.swift` |
| **New** | `MoolahTests/App/SessionManagerTests.swift` |
| **Edit** | `App/MoolahApp.swift` |
| **Edit** | `App/ProfileRootView.swift` (scope to iOS) |
| **Edit** | `App/SessionRootView.swift` (add focusedValue) |
| **Edit** | `Features/Profiles/ProfileCommands.swift` |
| **Edit** | `Features/Auth/UserMenuView.swift` |
| **Edit** | `Features/Settings/SettingsView.swift` |

## What Does NOT Change

- `ProfileSession` — already supports this design as-is
- `ProfileStore` — shared across windows, no changes needed
- All domain models, repositories, backend implementations
- All stores (`AuthStore`, `AccountStore`, etc.)
- `ContentView`, `SidebarView`, all feature views
- iOS behavior (profile switching, user menu, settings)
- `project.yml` (new files auto-included by existing path globs)

## Open Questions (Verify During Implementation)

1. **Duplicate window prevention:** Does `WindowGroup(for:)` + `openWindow(value:)` automatically bring an existing window to front? If not, need `NSApp.windows` lookup.
2. **First-run → first profile transition:** How does the nil-ID window transition after profile creation? May need `openWindow` + `dismiss` or the binding updates automatically.
3. **Window restoration persistence:** Confirm SwiftUI persists the `Profile.ID` values across app launches for `WindowGroup(for:)`.
4. **Settings window session access:** Confirm `SessionManager` environment injection reaches the `Settings` scene correctly (Settings scene is separate from WindowGroup).
