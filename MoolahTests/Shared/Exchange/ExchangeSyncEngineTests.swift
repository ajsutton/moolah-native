import Foundation
import Testing

@testable import Moolah

@Suite("ExchangeSyncEngine")
struct ExchangeSyncEngineTests {
  private static let optimism = Instrument.crypto(
    chainId: 10, contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP", name: "Optimism", decimals: 18)

  private func resolver(includeOP: Bool = false) -> ExchangeInstrumentResolver {
    ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(instruments: includeOP ? [Self.optimism] : []),
      fiatInstrument: .AUD)
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
    return try await ExchangeSyncEngine(resolver: resolver(includeOP: true))
      .build(account: account, imported: imported)
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
    let engine = ExchangeSyncEngine(resolver: resolver())
    let result = try await engine.build(account: account, imported: imported)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.quantity == -100)
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
    let engine = ExchangeSyncEngine(resolver: resolver())
    let result = try await engine.build(account: account, imported: imported)
    #expect(result.candidates.isEmpty)
  }
}
