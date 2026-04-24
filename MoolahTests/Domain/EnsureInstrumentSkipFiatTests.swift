import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ensureInstrument — skips fiat")
@MainActor
struct EnsureInstrumentSkipFiatTests {
  @Test
  func fiatDoesNotInsertInstrumentRecord() async throws {
    let repo = try makeContractCloudKitTransactionRepository()
    let context = repo.modelContainer.mainContext

    try repo.ensureInstrument(Instrument.fiat(code: "EUR"))
    try context.save()

    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == "EUR" }
    )
    let rows = try context.fetch(descriptor)
    #expect(rows.isEmpty)
  }

  @Test
  func stockStillInserts() async throws {
    let repo = try makeContractCloudKitTransactionRepository()
    let context = repo.modelContainer.mainContext

    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try repo.ensureInstrument(bhp)
    try context.save()

    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == "ASX:BHP.AX" }
    )
    let rows = try context.fetch(descriptor)
    #expect(rows.count == 1)
  }
}
