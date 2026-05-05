import Foundation
import Testing

@testable import Moolah

@Suite("WalletSyncState")
struct WalletSyncStateTests {
  @Test
  func roundTripsViaCodable() throws {
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 19_500_000,
      lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastError: .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_700_000_300))
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WalletSyncState.self, from: data)
    #expect(decoded == state)
  }

  @Test
  func defaultsToNilError() {
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 0,
      lastSyncedAt: Date(timeIntervalSince1970: 0),
      lastError: nil
    )
    #expect(state.lastError == nil)
  }
}
