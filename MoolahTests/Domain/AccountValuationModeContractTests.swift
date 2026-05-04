import Foundation
import Testing

@testable import Moolah

@Suite("AccountRepository Contract — valuationMode")
struct AccountValuationModeContractTests {

  @Test("valuationMode round-trips through create + fetchAll + update")
  func testValuationModeRoundTrip() async throws {
    let (backend, _) = try TestBackend.create()
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)

    let saved = try await backend.accounts.create(account, openingBalance: nil)
    #expect(saved.valuationMode == .calculatedFromTrades)

    let after = try await backend.accounts.fetchAll()
    let fetched = try #require(after.first { $0.id == saved.id })
    #expect(fetched.valuationMode == .calculatedFromTrades)

    var updated = fetched
    updated.valuationMode = .recordedValue
    let resaved = try await backend.accounts.update(updated)
    #expect(resaved.valuationMode == .recordedValue)

    let refetchedAll = try await backend.accounts.fetchAll()
    let refetched = try #require(refetchedAll.first { $0.id == saved.id })
    #expect(refetched.valuationMode == .recordedValue)
  }
}
