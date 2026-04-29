import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore -- Conversion")
@MainActor
struct AccountStoreConversionTestsExtra {
  @Test
  func mixedKindAccountShowsFiatAndStockPositions() async throws {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = Account(
      id: accountId, name: "Sharesight", type: .investment,
      instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: dec("5000.00"), type: .openingBalance)
      ]
    )
    let stockTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: Decimal(100),
          type: .transfer)
      ]
    )
    TestBackend.seed(transactions: [audTx, stockTx], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 2)
    #expect(positions.contains { $0.instrument == .AUD })
    #expect(positions.contains { $0.instrument == bhp })
  }

  @Test
  func mixedKindAccountShowsFiatStockAndCryptoPositions() async throws {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment,
      instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let txns = [
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD,
            quantity: dec("1000.00"), type: .openingBalance)
        ]),
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: Decimal(100),
            type: .transfer)
        ]),
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: eth,
            quantity: dec("0.5"), type: .transfer)
        ]),
    ]
    TestBackend.seed(transactions: txns, in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 3)
    let kinds = Set(positions.map(\.instrument.kind))
    #expect(kinds == [.fiatCurrency, .stock, .cryptoToken])
  }

  // MARK: - displayBalance

  @Test
  func displayBalanceSumsAllPositionsInAccountInstrument() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank, instrument: .AUD)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: dec("1000.00"), type: .openingBalance)
      ]
    )
    let usdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: dec("200.00"), type: .openingBalance)
      ]
    )
    TestBackend.seed(transactions: [audTx, usdTx], in: database)

    // 1 USD = 1.5 AUD
    let conversion = FixedConversionService(rates: ["USD": dec("1.5")])
    let store = AccountStore(
      repository: backend.accounts, conversionService: conversion,
      targetInstrument: .AUD)
    await store.load()

    let balance = try await store.displayBalance(for: accountId)
    #expect(balance.instrument == .AUD)
    // 1000 AUD + 200 USD * 1.5 = 1300 AUD
    #expect(balance.quantity == dec("1300.00"))
  }

  @Test
  func displayBalanceForSingleCurrencyAccountReturnsPrimaryPosition() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: dec("750.00"), type: .openingBalance)
      ]
    )
    TestBackend.seed(transactions: [transaction], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let balance = try await store.displayBalance(for: accountId)
    #expect(balance.quantity == dec("750.00"))
    #expect(balance.instrument == .defaultTestInstrument)
  }
}
