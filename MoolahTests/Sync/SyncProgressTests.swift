import Foundation
import Testing

@testable import Moolah

@Suite("SyncProgress")
@MainActor
struct SyncProgressTests {

  // MARK: - Initial state

  @Test
  func initialPhaseIsIdle() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    #expect(progress.phase == .idle)
    #expect(progress.recordsReceivedThisSession == 0)
    #expect(progress.pendingUploads == 0)
    #expect(progress.lastSettledAt == nil)
    #expect(progress.moreComing == false)
  }

  // MARK: - Receive transitions

  @Test
  func beginReceivingFromIdleEntersReceiving() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    #expect(progress.phase == .receiving)
  }

  @Test
  func beginReceivingWithPendingUploadsEntersSyncing() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.updatePendingUploads(5)
    progress.beginReceiving()
    #expect(progress.phase == .syncing)
  }

  // MARK: - Helpers

  private func makeDefaults() throws -> UserDefaults {
    let suite = "test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
