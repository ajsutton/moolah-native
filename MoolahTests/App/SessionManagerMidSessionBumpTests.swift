import Foundation
import Testing

@testable import Moolah

@Suite("SessionManager — mid-session bump arrival")
@MainActor
struct SessionManagerMidSessionBumpTests {
  @Test("remote bump above current tears down the active session")
  func tearsDownActiveSession() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let repository = containerManager.profileIndexRepositoryForTesting
    let coordinator = SyncCoordinator(containerManager: containerManager)
    let manager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: repository,
      syncCoordinator: coordinator)

    let id = UUID()
    let profile = Profile(id: id, label: "Test")
    try await repository.upsert(profile)
    if case .incompatible = await manager.session(for: profile) {
      Issue.record("expected .ready for initial open")
    }
    #expect(manager.sessions[id] != nil)

    // Simulate the remote bump: a higher version arrives via sync.
    var bumped = profile
    bumped.dataFormatVersion = DataFormatVersion.current + 1
    try await repository.upsert(bumped)

    // Drive the reconcile method directly — equivalent to what the
    // index observer would call on its callback path, but synchronous
    // from the test's perspective.
    await manager.reconcileIncompatibilityFromIndexForTesting()

    #expect(manager.sessions[id] == nil)
    #expect(manager.incompatibleProfiles[id] != nil)
    #expect(!coordinator.hasDataHandler(forProfile: id))
  }

  @Test("remote bump with no open session records an incompatibleProfiles entry only")
  func recordsEntryWhenNoSession() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let repository = containerManager.profileIndexRepositoryForTesting
    let coordinator = SyncCoordinator(containerManager: containerManager)
    let manager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: repository,
      syncCoordinator: coordinator)

    let id = UUID()
    let bumped = Profile(
      id: id, label: "Never opened",
      dataFormatVersion: DataFormatVersion.current + 1)
    try await repository.upsert(bumped)

    await manager.reconcileIncompatibilityFromIndexForTesting()

    #expect(manager.sessions[id] == nil)
    #expect(manager.incompatibleProfiles[id] != nil)
  }

  @Test("a successful .ready open clears any stale incompatibleProfiles entry")
  func readyOpenClearsStaleEntry() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let repository = containerManager.profileIndexRepositoryForTesting
    let manager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: repository)

    let id = UUID()
    let staleInfo = IncompatibleProfileInfo(
      profileLabel: "Stale", profileVersion: 9, buildVersion: 0)
    manager.setIncompatibleProfileForTesting(id: id, info: staleInfo)

    // Now store a compatible profile (e.g. after the user updates the app).
    let profile = Profile(id: id, label: "Stale", dataFormatVersion: 0)
    try await repository.upsert(profile)
    _ = await manager.session(for: profile)

    #expect(manager.incompatibleProfiles[id] == nil)
  }
}
