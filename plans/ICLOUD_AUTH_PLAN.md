# iCloud Migration — Authentication & User Identity

**Date:** 2026-04-08
**Component:** Authentication
**Parent plan:** [ICLOUD_MIGRATION_PLAN.md](./ICLOUD_MIGRATION_PLAN.md)

## Overview

Replace Google OAuth (via `RemoteAuthProvider`) with implicit iCloud identity (via `CloudKitAuthProvider`). This is the simplest component in the migration — iCloud authentication is handled at the OS level, so the app just needs to verify iCloud availability and retrieve user identity.

---

## Current Implementation

### RemoteAuthProvider (`Backends/Remote/Auth/RemoteAuthProvider.swift`)
- `requiresExplicitSignIn = true` — user must tap "Sign in with Google"
- `currentUser()` — calls `GET /api/auth/`, restores session cookies from Keychain
- `signIn()` — opens Google OAuth URL in browser, polls `POST /api/auth/token` every 2s for up to 5 minutes
- `signOut()` — calls `DELETE /api/auth/`, clears cookies from Keychain and HTTPCookieStorage

### AuthProvider Protocol (`Domain/Repositories/AuthProvider.swift`)
```swift
protocol AuthProvider: Sendable {
  var requiresExplicitSignIn: Bool { get }
  func currentUser() async throws -> UserProfile?
  func signIn() async throws -> UserProfile
  func signOut() async throws
}
```

### UserProfile (`Domain/Models/UserProfile.swift`)
```swift
struct UserProfile: Codable, Sendable, Equatable {
  let id: String          // "google-{google_id}" in current impl
  let givenName: String
  let familyName: String
  let pictureURL: URL?
}
```

### UI Behavior
- `WelcomeView` checks `requiresExplicitSignIn` — if `false`, it skips the sign-in button entirely
- `AuthStore` calls `currentUser()` on launch → routes to `.signedIn` or `.signedOut`
- `AppRootView` switches on auth state

---

## CloudKitAuthProvider Design

### File Location
`Backends/CloudKit/Auth/CloudKitAuthProvider.swift`

### Implementation

```swift
import CloudKit
import Foundation
import OSLog

final class CloudKitAuthProvider: AuthProvider, @unchecked Sendable {
  nonisolated let requiresExplicitSignIn = false

  private let container: CKContainer
  private let logger = Logger(subsystem: "com.moolah.app", category: "CloudKitAuth")

  init(container: CKContainer = .default()) {
    self.container = container
  }

  func currentUser() async throws -> UserProfile? {
    // Check if iCloud is available
    guard FileManager.default.ubiquityIdentityToken != nil else {
      logger.info("iCloud not available")
      return nil
    }

    do {
      let userRecordID = try await container.userRecordID()
      return UserProfile(
        id: "icloud-\(userRecordID.recordName)",
        givenName: "iCloud",
        familyName: "User",
        pictureURL: nil
      )
    } catch {
      logger.error("Failed to get iCloud user record: \(error.localizedDescription)")
      return nil
    }
  }

  func signIn() async throws -> UserProfile {
    guard FileManager.default.ubiquityIdentityToken != nil else {
      throw BackendError.unauthenticated
    }

    do {
      let userRecordID = try await container.userRecordID()
      return UserProfile(
        id: "icloud-\(userRecordID.recordName)",
        givenName: "iCloud",
        familyName: "User",
        pictureURL: nil
      )
    } catch {
      logger.error("iCloud sign-in failed: \(error.localizedDescription)")
      throw BackendError.unauthenticated
    }
  }

  func signOut() async throws {
    // No-op: iCloud sign-out is managed at the OS level (Settings > Apple ID).
    // The app cannot programmatically sign the user out of iCloud.
    logger.info("signOut called — no-op for iCloud auth")
  }
}
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| `requiresExplicitSignIn` | `false` | iCloud is always available if signed in at OS level |
| User identity | `CKContainer.userRecordID()` | Stable per-user identifier across devices |
| Profile name | "iCloud User" (placeholder) | CloudKit doesn't expose the user's real name without `discoverUserIdentity` permission |
| Sign out | No-op | Cannot sign out of iCloud programmatically |
| Error handling | Return `nil` from `currentUser()` | If iCloud is unavailable, treat as signed out |

---

## User Profile Considerations

### The Name Problem

CloudKit does not freely expose the iCloud user's real name. Options:

1. **Use `CKContainer.discoverUserIdentity(byUserRecordID:)`** — requires the user to grant "Look Me Up" permission in iCloud settings. May return the name but is not guaranteed.

2. **Use device owner name** — `UIDevice.current.name` (iOS) contains the device name (e.g., "Adrian's iPhone"), not reliably the user's name.

3. **Use a hardcoded placeholder** — "iCloud User" or similar. Since this is a single-user app, the name is only displayed in the user menu.

4. **Store a user-editable display name** — let the user set their name once in app settings, store it in SwiftData.

**Recommendation:** Option 4 (user-editable name) with Option 3 as default. The `UserProfile` returned by `currentUser()` uses "iCloud User" initially. A future settings screen can let the user customize their display name.

### Profile Picture

CloudKit does not provide a user profile picture. Options:
- Set `pictureURL` to `nil` (current `UserMenuView` already handles this with a fallback icon)
- Use SF Symbols person icon (already the fallback)

**Recommendation:** `pictureURL = nil`. The UI already handles this gracefully.

---

## iCloud Availability Checking

### Primary Check: `FileManager.default.ubiquityIdentityToken`
- Returns a non-nil opaque token if the user is signed into iCloud
- Fast, synchronous check
- Does not require CloudKit entitlements for the check itself

### Secondary Check: `CKContainer.accountStatus()`
- Returns `.available`, `.noAccount`, `.restricted`, `.couldNotDetermine`, `.temporarilyUnavailable`
- Async call
- More detailed than `ubiquityIdentityToken`

### Notification: `NSUbiquityIdentityDidChange`
- Posted when the user signs in/out of iCloud while the app is running
- `AuthStore` should observe this to update auth state reactively

### Implementation Strategy

```swift
// In CloudKitAuthProvider
func currentUser() async throws -> UserProfile? {
  // Fast check first
  guard FileManager.default.ubiquityIdentityToken != nil else { return nil }

  // Verify CloudKit container access
  let status = try await container.accountStatus()
  guard status == .available else {
    logger.warning("iCloud account status: \(String(describing: status))")
    return nil
  }

  let userRecordID = try await container.userRecordID()
  return makeProfile(from: userRecordID)
}
```

### Error States

| Condition | Behavior |
|-----------|----------|
| iCloud not signed in | `currentUser()` returns `nil` → AuthStore shows error prompt |
| iCloud restricted (parental controls) | `currentUser()` returns `nil` → show specific error |
| Network unavailable | `userRecordID()` may throw → return cached profile or nil |
| iCloud temporarily unavailable | Return cached profile if available |

---

## UI Changes

### WelcomeView
No changes needed. The view already checks `requiresExplicitSignIn`:
- When `false`, it auto-attempts sign-in without showing a button
- The `AuthStore.checkAuthState()` flow calls `currentUser()` on launch

### UserMenuView
Minor change needed:
- Currently shows "Sign Out" button
- For iCloud auth, either hide the sign-out button or show "Manage in Settings" since sign-out is a no-op
- Check `backend.auth.requiresExplicitSignIn` — if `false`, hide sign-out action

### AppRootView
No changes needed — already switches on `AuthStore.state`.

### New: iCloud Unavailable View
Create a view shown when iCloud is not available:
```swift
struct ICloudUnavailableView: View {
  var body: some View {
    ContentUnavailableView(
      "iCloud Required",
      systemImage: "icloud.slash",
      description: Text("Sign in to iCloud in Settings to use Moolah.")
    )
  }
}
```

---

## Testing Strategy

### Contract Tests
The existing `AuthContractTests` test `InMemoryAuthProvider`. Add a new suite for `CloudKitAuthProvider`:

```swift
@Suite("CloudKitAuthProvider")
struct CloudKitAuthProviderTests {
  @Test("requiresExplicitSignIn is false")
  func requiresExplicit() {
    let provider = CloudKitAuthProvider()
    #expect(provider.requiresExplicitSignIn == false)
  }

  @Test("signOut is a no-op")
  func signOutNoOp() async throws {
    let provider = CloudKitAuthProvider()
    // Should not throw
    try await provider.signOut()
  }
}
```

### Testability Challenge
`CKContainer` is not easily mockable. Options:
1. **Protocol wrapper** — define `CloudKitContainerProtocol` with `userRecordID()` and `accountStatus()`, make `CKContainer` conform via extension, inject mock in tests
2. **Integration tests only** — test against real CloudKit in CI (requires iCloud-signed-in Mac)
3. **Test via InMemoryAuthProvider** — the contract tests already validate behavior; CloudKitAuthProvider is thin enough to verify manually

**Recommendation:** Option 1 for unit tests. The protocol wrapper is small:

```swift
protocol CloudKitContainerProtocol: Sendable {
  func userRecordID() async throws -> CKRecord.ID
  func accountStatus() async throws -> CKAccountStatus
}

extension CKContainer: CloudKitContainerProtocol {}
```

---

## Migration Considerations

### Identity Transition
- The user's `UserProfile.id` changes from `"google-{id}"` to `"icloud-{recordName}"`
- This is acceptable because the user ID is only used for display, not as a foreign key in data models
- Transactions, accounts, etc. do not reference the user ID — they're implicitly scoped to the CloudKit private database

### Session Cleanup
During migration:
1. Export data from server (while still authenticated with Google OAuth)
2. Import data to SwiftData/CloudKit
3. Switch `BackendProvider` to `CloudKitBackend`
4. Clear Google OAuth cookies from Keychain (`CookieKeychain.clear()`)
5. Old `RemoteAuthProvider` code can be removed once migration is complete

### No Dual-Auth Period
The migration is a one-shot operation. The user is either on RemoteBackend or CloudKitBackend, never both simultaneously.

---

## Files to Create

| File | Purpose |
|------|---------|
| `Backends/CloudKit/Auth/CloudKitAuthProvider.swift` | AuthProvider implementation |
| `Backends/CloudKit/Auth/CloudKitContainerProtocol.swift` | Testability protocol wrapper |
| `Features/Auth/ICloudUnavailableView.swift` | Error view when iCloud is not available |
| `MoolahTests/Backends/CloudKitAuthProviderTests.swift` | Unit tests |

## Files to Modify

| File | Change |
|------|--------|
| `Features/Auth/UserMenuView.swift` | Hide sign-out when `requiresExplicitSignIn == false` |
| `Features/Auth/AuthStore.swift` | Observe `NSUbiquityIdentityDidChange` notification |

---

## Estimated Effort

| Task | Estimate |
|------|----------|
| `CloudKitAuthProvider` implementation | 2 hours |
| Protocol wrapper for testability | 1 hour |
| `ICloudUnavailableView` | 30 minutes |
| `UserMenuView` sign-out hiding | 30 minutes |
| `AuthStore` iCloud notification observer | 1 hour |
| Tests | 1 hour |
| **Total** | **~6 hours** |
