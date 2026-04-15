import Foundation
import Testing

@testable import Moolah

@Suite("Position")
struct PositionTests {
  let accountId = UUID()
  let aud = Instrument.AUD
  let usd = Instrument.USD

  @Test func initStoresProperties() {
    let pos = Position(accountId: accountId, instrument: aud, quantity: Decimal(string: "1500.00")!)
    #expect(pos.accountId == accountId)
    #expect(pos.instrument == aud)
    #expect(pos.quantity == Decimal(string: "1500.00")!)
  }

  @Test func amount() {
    let pos = Position(accountId: accountId, instrument: aud, quantity: Decimal(string: "1500.00")!)
    #expect(pos.amount.quantity == Decimal(string: "1500.00")!)
    #expect(pos.amount.instrument == aud)
  }

  @Test func computeFromLegsGroupsByInstrument() {
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(
        accountId: accountId, instrument: usd, quantity: Decimal(string: "50.00")!, type: .income),
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "-30.00")!, type: .expense),
    ]
    let positions = Position.compute(for: accountId, from: legs)
    #expect(positions.count == 2)

    let audPos = positions.first(where: { $0.instrument == aud })
    #expect(audPos?.quantity == Decimal(string: "70.00")!)

    let usdPos = positions.first(where: { $0.instrument == usd })
    #expect(usdPos?.quantity == Decimal(string: "50.00")!)
  }

  @Test func computeFiltersToAccount() {
    let otherAccount = UUID()
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(
        accountId: otherAccount, instrument: aud, quantity: Decimal(string: "200.00")!,
        type: .income),
    ]
    let positions = Position.compute(for: accountId, from: legs)
    #expect(positions.count == 1)
    #expect(positions.first?.quantity == Decimal(string: "100.00")!)
  }

  @Test func computeEmptyLegs() {
    let positions = Position.compute(for: accountId, from: [])
    #expect(positions.isEmpty)
  }

  @Test func computeExcludesZeroQuantity() {
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "-100.00")!,
        type: .expense),
    ]
    let positions = Position.compute(for: accountId, from: legs)
    #expect(positions.isEmpty)
  }

  @Test func hashableAndEquatable() {
    let a = Position(accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!)
    let b = Position(accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!)
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
  }
}
