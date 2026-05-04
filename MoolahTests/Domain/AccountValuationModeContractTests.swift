import Foundation
import Testing

@testable import Moolah

@Suite("Account ValuationMode Contract")
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

    let final = try await backend.accounts.fetchAll()
    let refetched = try #require(final.first { $0.id == saved.id })
    #expect(refetched.valuationMode == .recordedValue)
  }
}
