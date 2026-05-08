import Foundation
import Testing

@testable import Moolah

@Suite("TransactionLeg identity")
struct TransactionLegIdentityTests {

  @Test("default initializer allocates a fresh id per call")
  func defaultIdIsUnique() {
    let legA = TransactionLeg(
      accountId: nil,
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(0), type: .expense)
    let legB = TransactionLeg(
      accountId: nil,
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(0), type: .expense)
    #expect(legA.id != legB.id)
  }

  @Test("explicit id round-trips through init")
  func explicitIdRoundTrips() {
    let id = UUID()
    let leg = TransactionLeg(
      id: id,
      accountId: nil,
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(0), type: .expense)
    #expect(leg.id == id)
  }

  @Test("two legs with same content but different ids are not equal")
  func differentIdsBreakEquality() {
    let legA = TransactionLeg(
      accountId: nil,
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(0), type: .expense)
    let legB = TransactionLeg(
      accountId: nil,
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(0), type: .expense)
    // Same content, distinct identities: must compare unequal.
    // Downstream callers (e.g. diff-by-id update flows) rely on Equatable
    // (satisfied via Hashable) to detect that two legs with the same
    // content but different ids are not interchangeable.
    #expect(legA != legB)
  }

  @Test("legacy JSON without id decodes with a fresh non-nil id")
  func legacyJSONWithoutIdDecodesWithFreshId() throws {
    // Mirrors the legacy-row JSON shape from `TransactionLegTests`'s
    // backward-compat decode tests but specifically pins the `id` field
    // behaviour: the custom `init(from:)` must allocate a fresh UUID
    // when `id` is absent, not throw `keyNotFound`.
    let json = Data(
      """
      {"accountId":"\(UUID().uuidString)",\
      "instrument":{"id":"AUD","kind":"fiatCurrency","name":"AUD","decimals":2},\
      "quantity":100,"type":"income"}
      """.utf8)
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: json)
    // Two decodes of the same legacy payload must produce different ids
    // (each fresh allocation), ruling out the "constant default" trap.
    let secondDecode = try JSONDecoder().decode(TransactionLeg.self, from: json)
    #expect(decoded.id != secondDecode.id)
  }

  @Test("paidCopy(of:) allocates fresh ids for every leg")
  func paidCopyAllocatesFreshLegIds() {
    let scheduled = Transaction(
      date: Date(), payee: "Rent",
      legs: [
        TransactionLeg(
          accountId: UUID(),
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-1000), type: .expense),
        TransactionLeg(
          accountId: UUID(),
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(1000), type: .transfer),
      ])
    let copy = Transaction.paidCopy(of: scheduled)
    let scheduledIds = Set(scheduled.legs.map(\.id))
    let copyIds = Set(copy.legs.map(\.id))
    // Different transactions, distinct leg rows: ids must not collide.
    #expect(scheduledIds.isDisjoint(with: copyIds))
    #expect(copy.legs.count == scheduled.legs.count)
    // Content is preserved.
    #expect(copy.legs.map(\.quantity) == scheduled.legs.map(\.quantity))
  }
}
