import Foundation
import Testing

@testable import Moolah

// Verifies `SyncCoordinator.startAfter(profileIndexMigration:start:)`
// does not invoke the start closure until the supplied profile-index
// migration task completes. Production wiring relies on this so
// CKSyncEngine cannot deliver fetched profile-data zone changes
// before the local profile index is hydrated; otherwise
// `SyncCoordinator.handlerForProfileZone(profileId:zoneID:)` traps
// for any profile zone whose `ProfileSession` has not yet been
// constructed.
@Suite("SyncCoordinator start gate")
@MainActor
struct SyncCoordinatorStartGateTests {
  private func makeCoordinator() throws -> SyncCoordinator {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = try #require(
      UserDefaults(suiteName: "sync-start-gate-\(UUID().uuidString)"))
    return SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults,
      isCloudKitAvailable: false)
  }

  @Test("start closure is not invoked while the migration task is pending")
  func startAfterWaitsForMigration() async throws {
    let coordinator = try makeCoordinator()
    let counter = StartCounter()

    let release = AsyncStream<Void>.makeStream()
    let migration = Task<Void, Never> {
      for await _ in release.stream { return }
    }

    coordinator.startAfter(
      profileIndexMigration: migration,
      start: { counter.increment() })

    // Give the launch task plenty of opportunity to begin awaiting.
    for _ in 0..<10 { await Task.yield() }

    #expect(counter.value == 0)

    release.continuation.finish()
    await coordinator.launchTask?.value

    #expect(counter.value == 1)
  }

  @Test("start closure runs immediately when the migration task is nil")
  func startAfterWithNilMigrationStartsImmediately() async throws {
    let coordinator = try makeCoordinator()
    let counter = StartCounter()

    coordinator.startAfter(
      profileIndexMigration: nil,
      start: { counter.increment() })
    await coordinator.launchTask?.value

    #expect(counter.value == 1)
  }

  @Test("start closure runs immediately when the migration task already finished")
  func startAfterWithCompletedMigrationStartsImmediately() async throws {
    let coordinator = try makeCoordinator()
    let counter = StartCounter()

    let migration = Task<Void, Never> {}
    await migration.value

    coordinator.startAfter(
      profileIndexMigration: migration,
      start: { counter.increment() })
    await coordinator.launchTask?.value

    #expect(counter.value == 1)
  }

  @Test("stop() cancels a pending launch and skips the start invocation")
  func stopCancelsPendingLaunch() async throws {
    let coordinator = try makeCoordinator()
    let counter = StartCounter()

    let release = AsyncStream<Void>.makeStream()
    let migration = Task<Void, Never> {
      for await _ in release.stream { return }
    }

    coordinator.startAfter(
      profileIndexMigration: migration,
      start: { counter.increment() })

    for _ in 0..<5 { await Task.yield() }

    // Tear the coordinator down while the launch task is still
    // awaiting the migration. The post-await `Task.isCancelled`
    // guard must skip the start invocation.
    coordinator.stop()
    release.continuation.finish()
    if let launchTask = coordinator.launchTask { await launchTask.value }

    #expect(counter.value == 0)
  }
}

// Reference-typed `@MainActor` counter the injected `start` closure
// can mutate. A local `var` would be captured by reference too, but
// `@MainActor @Sendable () -> Void` rejects mutable-var captures in
// strict-concurrency mode, so the closure needs to write through a
// reference instead.
@MainActor
private final class StartCounter {
  private(set) var value = 0

  func increment() { value += 1 }
}
