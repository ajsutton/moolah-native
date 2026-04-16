import Foundation
import Testing

@testable import Moolah

@Suite("Position")
struct PositionTests {
  let accountId = UUID()
  let aud = Instrument.AUD
  let usd = Instrument.USD

  @Test func initStoresProperties() {
    let pos = Position(instrument: aud, quantity: Decimal(string: "1500.00")!)
    #expect(pos.instrument == aud)
    #expect(pos.quantity == Decimal(string: "1500.00")!)
  }

  @Test func amount() {
    let pos = Position(instrument: aud, quantity: Decimal(string: "1500.00")!)
    #expect(pos.amount.quantity == Decimal(string: "1500.00")!)
    #expect(pos.amount.instrument == aud)
  }

  @Test func computeForAccountGroupsByInstrument() {
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(
        accountId: accountId, instrument: usd, quantity: Decimal(string: "50.00")!, type: .income),
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "-30.00")!, type: .expense),
    ]
    let positions = Position.computeForAccount(accountId, from: legs)
    #expect(positions.count == 2)

    let audPos = positions.first(where: { $0.instrument == aud })
    #expect(audPos?.quantity == Decimal(string: "70.00")!)

    let usdPos = positions.first(where: { $0.instrument == usd })
    #expect(usdPos?.quantity == Decimal(string: "50.00")!)
  }

  @Test func computeForAccountFiltersToAccount() {
    let otherAccount = UUID()
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(
        accountId: otherAccount, instrument: aud, quantity: Decimal(string: "200.00")!,
        type: .income),
    ]
    let positions = Position.computeForAccount(accountId, from: legs)
    #expect(positions.count == 1)
    #expect(positions.first?.quantity == Decimal(string: "100.00")!)
  }

  @Test func computeForAccountEmptyLegs() {
    let positions = Position.computeForAccount(accountId, from: [])
    #expect(positions.isEmpty)
  }

  @Test func computeForAccountExcludesZeroQuantity() {
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(string: "-100.00")!,
        type: .expense),
    ]
    let positions = Position.computeForAccount(accountId, from: legs)
    #expect(positions.isEmpty)
  }

  @Test func computeForEarmarkGroupsByInstrument() {
    let earmarkId = UUID()
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud,
        quantity: Decimal(string: "100.00")!, type: .income, earmarkId: earmarkId),
      TransactionLeg(
        accountId: accountId, instrument: usd,
        quantity: Decimal(string: "50.00")!, type: .income, earmarkId: earmarkId),
      TransactionLeg(
        accountId: accountId, instrument: aud,
        quantity: Decimal(string: "-30.00")!, type: .expense, earmarkId: earmarkId),
    ]
    let positions = Position.computeForEarmark(earmarkId, from: legs)
    #expect(positions.count == 2)

    let audPos = positions.first(where: { $0.instrument == aud })
    #expect(audPos?.quantity == Decimal(string: "70.00")!)

    let usdPos = positions.first(where: { $0.instrument == usd })
    #expect(usdPos?.quantity == Decimal(string: "50.00")!)
  }

  @Test func computeForEarmarkFiltersToEarmark() {
    let earmarkId = UUID()
    let otherEarmarkId = UUID()
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud,
        quantity: Decimal(string: "100.00")!, type: .income, earmarkId: earmarkId),
      TransactionLeg(
        accountId: accountId, instrument: aud,
        quantity: Decimal(string: "200.00")!, type: .income, earmarkId: otherEarmarkId),
    ]
    let positions = Position.computeForEarmark(earmarkId, from: legs)
    #expect(positions.count == 1)
    #expect(positions.first?.quantity == Decimal(string: "100.00")!)
  }

  @Test func hashableAndEquatable() {
    let a = Position(instrument: aud, quantity: Decimal(string: "100.00")!)
    let b = Position(instrument: aud, quantity: Decimal(string: "100.00")!)
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
  }

  // MARK: - applying(deltas:)

  @Test func applyingDeltasToEmptyPositionsCreatesNewPosition() {
    let positions: [Position] = []
    let result = positions.applying(deltas: [aud: Decimal(string: "100.00")!])
    #expect(result.count == 1)
    #expect(result.first?.instrument == aud)
    #expect(result.first?.quantity == Decimal(string: "100.00")!)
  }

  @Test func applyingDeltasToExistingPositionAdjustsQuantity() {
    let positions = [Position(instrument: aud, quantity: Decimal(string: "100.00")!)]
    let result = positions.applying(deltas: [aud: Decimal(string: "50.00")!])
    #expect(result.count == 1)
    #expect(result.first?.quantity == Decimal(string: "150.00")!)
  }

  @Test func applyingDeltaForNewInstrumentAddsIt() {
    let positions = [Position(instrument: aud, quantity: Decimal(string: "100.00")!)]
    let result = positions.applying(deltas: [usd: Decimal(string: "50.00")!])
    #expect(result.count == 2)
    let audPos = result.first(where: { $0.instrument == aud })
    let usdPos = result.first(where: { $0.instrument == usd })
    #expect(audPos?.quantity == Decimal(string: "100.00")!)
    #expect(usdPos?.quantity == Decimal(string: "50.00")!)
  }

  @Test func applyingDeltaThatZeroesOutRemovesPosition() {
    let positions = [Position(instrument: aud, quantity: Decimal(string: "100.00")!)]
    let result = positions.applying(deltas: [aud: Decimal(string: "-100.00")!])
    #expect(result.isEmpty)
  }

  @Test func applyingDeltasResultsSortedByInstrumentId() {
    let positions: [Position] = []
    let result = positions.applying(deltas: [
      usd: Decimal(string: "50.00")!,
      aud: Decimal(string: "100.00")!,
    ])
    #expect(result.count == 2)
    // AUD sorts before USD alphabetically
    #expect(result[0].instrument == aud)
    #expect(result[1].instrument == usd)
  }
}
