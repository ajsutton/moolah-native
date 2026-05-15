import Foundation
import Testing

@testable import Moolah

/// Covers the stale-`activeProfileID` recovery path in
/// `ProfileStore.applyLoadedProfiles(_:isInitialLoad:)`. The active
/// profile may be deleted on another device — or the local
/// `activeProfileID` UserDefault may simply not match the loaded set
/// (e.g. switching between Debug and Release builds, which share a
/// bundle id but talk to different CloudKit containers). On the next
/// launch the initial load returns a non-empty profile list whose ids
/// don't include the stale one, and without the recovery the store
/// stays pinned to a phantom id forever — `SessionManager.sessions[id]`
/// returns nil for the active id, which silently hides the per-profile
/// Settings tabs (Crypto especially) even though the main app still
/// renders via fallbacks.
@Suite("ProfileStore — stale activeProfileID recovery")
@MainActor
struct ProfileStoreStaleActiveIDRecoveryTests {
  private func makeDefaults(staleID: UUID? = nil) throws -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    if let staleID {
      defaults.set(staleID.uuidString, forKey: ProfileStore.activeProfileKey)
    }
    return defaults
  }

  @Test("initial load with stale activeProfileID switches to first loaded profile")
  func initialLoadRecoversFromStaleActiveID() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let real = try await seedCloudProfile(manager)
    let staleID = UUID()
    #expect(staleID != real.id)
    let defaults = try makeDefaults(staleID: staleID)

    let store = ProfileStore(defaults: defaults, containerManager: manager)
    await drainPendingMutations(store)

    #expect(store.activeProfileID == real.id)
    #expect(
      defaults.string(forKey: ProfileStore.activeProfileKey) == real.id.uuidString
    )
  }

  @Test("initial empty load preserves stale activeProfileID (stale-empty guard)")
  func initialEmptyLoadDoesNotClearStaleID() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let staleID = UUID()
    let defaults = try makeDefaults(staleID: staleID)

    // No profile seeded — initial load returns []. The recovery path
    // must not fire here; an empty result during the launch race
    // (SwiftData → GRDB profile-index migration in flight) is
    // legitimately empty and is handled by `scheduleRetryIfNeeded()`.
    let store = ProfileStore(defaults: defaults, containerManager: manager)
    await drainPendingMutations(store)

    #expect(store.activeProfileID == staleID)
  }

  @Test("initial load suppresses recovery while welcomePhase == .creating")
  func initialLoadRespectsWelcomeCreatingRace() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let real = try await seedCloudProfile(manager)
    let staleID = UUID()
    #expect(staleID != real.id)
    let defaults = try makeDefaults(staleID: staleID)

    let store = ProfileStore(defaults: defaults, containerManager: manager)
    // Set the creating phase before the async load body finishes.
    // `drainPendingMutations` waits for it to commit.
    store.welcomePhase = .creating
    await drainPendingMutations(store)

    // The race-protection contract mirrors the auto-activate path:
    // while WelcomeView is mid-create, the in-flight cloud load must
    // not rewrite `activeProfileID` underneath the user's tap.
    #expect(store.activeProfileID == staleID)
  }

  @Test("initial load with matching activeProfileID leaves it untouched")
  func initialLoadKeepsValidActiveID() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let real = try await seedCloudProfile(manager)
    let defaults = try makeDefaults(staleID: real.id)

    let store = ProfileStore(defaults: defaults, containerManager: manager)
    await drainPendingMutations(store)

    #expect(store.activeProfileID == real.id)
    // The recovery branch must short-circuit before
    // `saveActiveProfileID()`; the persisted value is unchanged.
    #expect(
      defaults.string(forKey: ProfileStore.activeProfileKey) == real.id.uuidString
    )
  }
}
