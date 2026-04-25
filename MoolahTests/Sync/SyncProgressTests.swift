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

  // MARK: - Counter accumulation

  @Test
  func recordReceivedAdvancesCounter() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 10, deletions: 3, moreComing: true)
    #expect(progress.recordsReceivedThisSession == 13)
  }

  @Test
  func recordReceivedCapturesMoreComing() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 10, deletions: 3, moreComing: true)
    #expect(progress.moreComing == true)
  }

  @Test
  func recordReceivedCounterIsAdditiveAcrossBatches() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 5, deletions: 0, moreComing: true)
    progress.recordReceived(modifications: 7, deletions: 2, moreComing: false)
    #expect(progress.recordsReceivedThisSession == 14)
  }

  @Test
  func recordReceivedMoreComingIsOverwrittenEachBatch() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 5, deletions: 0, moreComing: true)
    progress.recordReceived(modifications: 7, deletions: 2, moreComing: false)
    #expect(progress.moreComing == false)
  }

  // MARK: - Settle

  @Test
  func endReceivingWithNoPendingSettlesPhase() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 4, deletions: 0, moreComing: false)
    progress.endReceiving(now: Date(timeIntervalSince1970: 1_000_000))
    #expect(progress.phase == .upToDate)
  }

  @Test
  func endReceivingWithNoPendingResetsCounter() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 4, deletions: 0, moreComing: false)
    progress.endReceiving(now: Date(timeIntervalSince1970: 1_000_000))
    #expect(progress.recordsReceivedThisSession == 0)
  }

  @Test
  func endReceivingWithNoPendingRecordsLastSettledAt() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 4, deletions: 0, moreComing: false)
    let now = Date(timeIntervalSince1970: 1_000_000)
    progress.endReceiving(now: now)
    #expect(progress.lastSettledAt == now)
  }

  @Test
  func endReceivingWithEmptySessionSettlesPhase() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.endReceiving(now: Date(timeIntervalSince1970: 1_000_000))
    #expect(progress.phase == .upToDate)
  }

  @Test
  func endReceivingWithEmptySessionRecordsLastSettledAt() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    let now = Date(timeIntervalSince1970: 1_000_000)
    progress.endReceiving(now: now)
    #expect(progress.lastSettledAt == now)
  }

  @Test
  func endReceivingWithPendingUploadsTransitionsToSending() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.updatePendingUploads(7)
    progress.beginReceiving()
    progress.endReceiving(now: Date(timeIntervalSince1970: 1_000_000))
    #expect(progress.phase == .sending)
  }

  @Test
  func endReceivingWithPendingUploadsResetsCounter() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.updatePendingUploads(7)
    progress.beginReceiving()
    progress.endReceiving(now: Date(timeIntervalSince1970: 1_000_000))
    #expect(progress.recordsReceivedThisSession == 0)
  }

  @Test
  func endReceivingWithPendingUploadsDoesNotAdvanceLastSettledAt() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.updatePendingUploads(7)
    progress.beginReceiving()
    progress.endReceiving(now: Date(timeIntervalSince1970: 1_000_000))
    #expect(progress.lastSettledAt == nil)
  }

  @Test
  func endReceivingResetsMoreComing() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 1, deletions: 0, moreComing: true)
    progress.endReceiving(now: Date(timeIntervalSince1970: 1_000_000))
    #expect(progress.moreComing == false)
  }

  @Test
  func endReceivingWithPendingUploadsResetsMoreComing() throws {
    let progress = SyncProgress(userDefaults: try makeDefaults())
    progress.updatePendingUploads(3)
    progress.beginReceiving()
    progress.recordReceived(modifications: 1, deletions: 0, moreComing: true)
    progress.endReceiving(now: Date(timeIntervalSince1970: 1_000_000))
    #expect(progress.moreComing == false)
  }

  // MARK: - Helpers

  private func makeDefaults() throws -> UserDefaults {
    let suite = "test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
