import Foundation
import Testing

@testable import Moolah

// Swift Testing's `@Test func foo()` is the documented idiom, and
// swift-format's `lineBreakBetweenDeclarationAttributes: false` keeps the
// attribute inline. Disable SwiftLint's `attributes` rule in this file so
// the formatter and the linter don't fight over the same layout.
// swiftlint:disable attributes

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

  // MARK: - Multi-kind positions (fiat + stock + crypto)

  @Test func computeForAccountAggregatesAcrossInstrumentKinds() {
    // Account holds fiat, stock, and crypto simultaneously.
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud,
        quantity: Decimal(string: "1000.00")!, type: .openingBalance),
      TransactionLeg(
        accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
      TransactionLeg(
        accountId: accountId, instrument: eth,
        quantity: Decimal(string: "0.5")!, type: .transfer),
    ]
    let positions = Position.computeForAccount(accountId, from: legs)
    #expect(positions.count == 3)

    let audPos = positions.first(where: { $0.instrument == aud })
    let bhpPos = positions.first(where: { $0.instrument == bhp })
    let ethPos = positions.first(where: { $0.instrument == eth })
    #expect(audPos?.quantity == Decimal(string: "1000.00")!)
    #expect(bhpPos?.quantity == Decimal(150))
    #expect(ethPos?.quantity == Decimal(string: "0.5")!)
  }

  @Test func computeForAccountSortsByInstrumentIdAcrossKinds() {
    // Sort is lexicographic over instrument.id — "0:native" (BTC), "1:native" (ETH),
    // "ASX:BHP", "AUD", "JPY", "NASDAQ:AAPL", "USD" under ASCII ordering.
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "AAPL")
    let jpy = Instrument.fiat(code: "JPY")

    let legs = [
      TransactionLeg(accountId: accountId, instrument: usd, quantity: Decimal(1), type: .income),
      TransactionLeg(
        accountId: accountId, instrument: bhp, quantity: Decimal(1), type: .transfer),
      TransactionLeg(accountId: accountId, instrument: btc, quantity: Decimal(1), type: .transfer),
      TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(1), type: .income),
      TransactionLeg(accountId: accountId, instrument: jpy, quantity: Decimal(1), type: .income),
      TransactionLeg(accountId: accountId, instrument: eth, quantity: Decimal(1), type: .transfer),
      TransactionLeg(
        accountId: accountId, instrument: aapl, quantity: Decimal(1), type: .transfer),
    ]
    let positions = Position.computeForAccount(accountId, from: legs)
    #expect(positions.count == 7)
    let ids = positions.map { $0.instrument.id }
    #expect(ids == ids.sorted())
  }

  @Test func computeForAccountDoesNotMergeDifferentKindsWithSameSymbol() {
    // Guard: a fiat "USD" and a crypto with id "1:usdc" must be distinct positions.
    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6
    )
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: usd,
        quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(
        accountId: accountId, instrument: usdc,
        quantity: Decimal(string: "100.00")!, type: .transfer),
    ]
    let positions = Position.computeForAccount(accountId, from: legs)
    #expect(positions.count == 2)
    #expect(positions.contains(where: { $0.instrument == usd }))
    #expect(positions.contains(where: { $0.instrument == usdc }))
  }

  @Test func applyingDeltasWithMixedKindsKeepsPositionsDistinct() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    let positions = [
      Position(instrument: aud, quantity: Decimal(string: "1000.00")!)
    ]
    let result = positions.applying(deltas: [
      bhp: Decimal(100),
      btc: Decimal(string: "0.1")!,
    ])
    #expect(result.count == 3)
    #expect(result.map { $0.instrument.id } == ["0:native", "ASX:BHP", "AUD"])
  }

  @Test func zeroOutOneKindDoesNotRemoveOthers() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    // Sell entire BHP position while leaving AUD cash intact.
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud,
        quantity: Decimal(string: "2000.00")!, type: .openingBalance),
      TransactionLeg(
        accountId: accountId, instrument: bhp, quantity: Decimal(100), type: .transfer),
      TransactionLeg(
        accountId: accountId, instrument: bhp, quantity: Decimal(-100), type: .transfer),
    ]
    let positions = Position.computeForAccount(accountId, from: legs)
    #expect(positions.count == 1)
    #expect(positions.first?.instrument == aud)
    #expect(positions.first?.quantity == Decimal(string: "2000.00")!)
  }
}

// swiftlint:enable attributes
