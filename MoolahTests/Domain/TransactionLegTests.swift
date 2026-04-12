import Foundation
import Testing

@testable import Moolah

@Suite("TransactionLeg")
struct TransactionLegTests {
  let accountId = UUID()
  let aud = Instrument.AUD

  @Test func expenseLeg() {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: Decimal(string: "-50.00")!,
      type: .expense
    )
    #expect(leg.accountId == accountId)
    #expect(leg.instrument == aud)
    #expect(leg.quantity == Decimal(string: "-50.00")!)
    #expect(leg.type == .expense)
    #expect(leg.categoryId == nil)
    #expect(leg.earmarkId == nil)
  }

  @Test func legWithCategoryAndEarmark() {
    let catId = UUID()
    let earId = UUID()
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: Decimal(string: "-50.00")!,
      type: .expense,
      categoryId: catId,
      earmarkId: earId
    )
    #expect(leg.categoryId == catId)
    #expect(leg.earmarkId == earId)
  }

  @Test func codableRoundTrip() throws {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: Decimal(string: "-50.23")!,
      type: .expense,
      categoryId: UUID()
    )
    let data = try JSONEncoder().encode(leg)
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: data)
    #expect(decoded == leg)
  }

  @Test func amount() {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: Decimal(string: "-50.23")!,
      type: .expense
    )
    #expect(leg.amount == InstrumentAmount(quantity: Decimal(string: "-50.23")!, instrument: aud))
  }
}
