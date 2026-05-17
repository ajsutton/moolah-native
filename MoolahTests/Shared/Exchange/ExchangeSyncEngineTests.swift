import Foundation
import Testing

@testable import Moolah

@Suite("ExchangeSyncEngine")
struct ExchangeSyncEngineTests {
  private static let optimism = Instrument.crypto(
    chainId: 10, contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP", name: "Optimism", decimals: 18)

  /// Metadata stub that returns real OP EVM chain data for "OP", and nil
  /// for anything else. Used by tests that include OP asset legs.
  private static let opMetadata = StubMetadata([
    "OP": ExchangeAssetMetadata(
      symbol: "OP", name: "Optimism",
      chains: [
        ExchangeAssetChain(
          chainId: 10,
          contractAddress: "0x4200000000000000000000000000000000000042",
          decimals: 18)
      ])
  ])

  /// Empty metadata stub: returns nil for every symbol, so only the
  /// registry-fallback path is exercised (fiat legs still short-circuit
  /// before any metadata call).
  private static let emptyMetadata = StubMetadata([:])

  private func makeEngine(
    registry: StubInstrumentRegistry = StubInstrumentRegistry()
  ) -> ExchangeSyncEngine {
    let regResolver = CountingRegistrationResolver()
    regResolver.setDefault(.success(coingecko: "id", cryptocompare: nil, binance: nil))
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: regResolver, alchemy: CountingAlchemyClientStub())
    return ExchangeSyncEngine(
      resolver: ExchangeInstrumentResolver(
        registry: registry, fiatInstrument: .AUD,
        existingLegInstrumentIds: { [] }),
      discovery: discovery)
  }

  private func tradeAndDepositResult() async throws -> WalletSyncBuildResult {
    let account = Account(
      name: "Coinstash", type: .exchange,
      instrument: .AUD, exchangeProvider: .coinstash)
    let imported = [
      ExchangeImportedTransaction(
        externalId: "t1", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADE", direction: .credit, assetSymbol: "OP", amount: 50,
        isFiat: false, orderId: "o1"),
      ExchangeImportedTransaction(
        externalId: "t2", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADE", direction: .debit, assetSymbol: nil, amount: 100,
        isFiat: true, orderId: "o1"),
      ExchangeImportedTransaction(
        externalId: "t3", occurredAt: Date(timeIntervalSince1970: 200),
        category: "DEPOSIT", direction: .credit, assetSymbol: nil, amount: 500,
        isFiat: true, orderId: nil),
    ]
    return try await makeEngine()
      .build(account: account, imported: imported, metadata: Self.opMetadata)
  }

  @Test
  func headBlockNumberIsAlwaysZero() async throws {
    let result = try await tradeAndDepositResult()
    #expect(result.headBlockNumber == 0)
  }

  @Test
  func groupsTradeLegsByOrderId() async throws {
    let result = try await tradeAndDepositResult()
    #expect(result.candidates.count == 2)
  }

  @Test
  func tradeGroupHasTwoLegs() async throws {
    let result = try await tradeAndDepositResult()
    #expect(result.candidates.contains { $0.transaction.legs.count == 2 })
  }

  @Test
  func debitLegProducesNegativeQuantity() async throws {
    let account = Account(
      name: "X", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let imported = [
      ExchangeImportedTransaction(
        externalId: "t1", occurredAt: Date(timeIntervalSince1970: 100),
        category: "DEPOSIT", direction: .debit, assetSymbol: nil,
        amount: 100, isFiat: true, orderId: nil)
    ]
    let result = try await makeEngine()
      .build(account: account, imported: imported, metadata: Self.emptyMetadata)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.quantity == -100)
  }

  @Test
  func tradeFeeLegIsExpenseNotTrade() async throws {
    let account = Account(
      name: "Coinstash", type: .exchange,
      instrument: .AUD, exchangeProvider: .coinstash)
    let imported = [
      ExchangeImportedTransaction(
        externalId: "t1", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADE", direction: .debit, assetSymbol: "OP", amount: 20167,
        isFiat: false, orderId: "o1"),
      ExchangeImportedTransaction(
        externalId: "t2", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADE", direction: .credit, assetSymbol: nil, amount: 3518.46,
        isFiat: true, orderId: "o1"),
      ExchangeImportedTransaction(
        externalId: "t3", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADEFEE", direction: .debit, assetSymbol: nil, amount: 21.11,
        isFiat: true, orderId: "o1"),
    ]
    let result = try await makeEngine()
      .build(account: account, imported: imported, metadata: Self.opMetadata)
    let legs = try #require(result.candidates.first?.transaction.legs)
    let feeLeg = try #require(legs.first { $0.externalId == "t3" })
    #expect(feeLeg.type == .expense)
    #expect(feeLeg.quantity == Decimal(string: "-21.11"))
    // The fee stays grouped with its trade (grouping is by orderId).
    #expect(legs.count == 3)
    let tradeLeg = try #require(legs.first { $0.externalId == "t1" })
    #expect(tradeLeg.type == .trade)
  }

  @Test
  func dropsEntireGroupWhenAnyLegUnresolvable() async throws {
    let account = Account(
      name: "X", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let imported = [
      ExchangeImportedTransaction(
        externalId: "t1", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADE", direction: .credit, assetSymbol: "UNKNOWNCOIN",
        amount: 1, isFiat: false, orderId: "o1"),
      ExchangeImportedTransaction(
        externalId: "t2", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADE", direction: .debit, assetSymbol: nil,
        amount: 100, isFiat: true, orderId: "o1"),
    ]
    // emptyMetadata returns nil for UNKNOWNCOIN; registry is empty too →
    // fallbackInstrument returns nil → whole group is dropped.
    let result = try await makeEngine()
      .build(account: account, imported: imported, metadata: Self.emptyMetadata)
    #expect(result.candidates.isEmpty)
  }
}
