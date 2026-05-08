import Foundation
import Testing

@testable import Moolah

@Suite("TransactionLegRow mapping round-trip")
struct TransactionLegRowMappingTests {

  @Test("factory init defaults to leg.id; toDomain round-trips it back")
  func legIdRoundTripsThroughMappingFactory() throws {
    let stableId = UUID()
    let leg = TransactionLeg(
      id: stableId,
      accountId: nil,
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10),
      type: .expense)

    let row = TransactionLegRow(
      domain: leg,
      transactionId: UUID(),
      sortOrder: 0)
    #expect(row.id == stableId)

    let domain = try row.toDomain(instrument: Instrument.defaultTestInstrument)
    #expect(domain.id == stableId)
  }

  @Test("factory init explicit id overrides leg.id")
  func explicitIdOverridesLegId() {
    let overrideId = UUID()
    let leg = TransactionLeg(
      accountId: nil,
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10),
      type: .expense)

    let row = TransactionLegRow(
      id: overrideId,
      domain: leg,
      transactionId: UUID(),
      sortOrder: 0)
    #expect(row.id == overrideId)
    #expect(row.id != leg.id)
  }

  @Test("factory init derives recordName from the resolved id")
  func recordNameDerivesFromResolvedId() {
    let stableId = UUID()
    let leg = TransactionLeg(
      id: stableId,
      accountId: nil,
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10),
      type: .expense)

    let row = TransactionLegRow(
      domain: leg,
      transactionId: UUID(),
      sortOrder: 0)
    #expect(row.recordName == TransactionLegRow.recordName(for: stableId))
  }
}
