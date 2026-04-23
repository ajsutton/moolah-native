import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountRepository Contract")
struct AccountRepositoryContractTests {

  // MARK: - CREATE TESTS

  @Test("creates account with opening balance")
  func testCreatesAccount() async throws {
    let repository = try makeCloudKitAccountRepository()
    let newAccount = Account(
      name: "Savings",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    let openingBalance = InstrumentAmount(quantity: 1000, instrument: .defaultTestInstrument)

    let created = try await repository.create(newAccount, openingBalance: openingBalance)

    #expect(created.id == newAccount.id)
    #expect(created.name == "Savings")

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
    // Balance is reflected in positions after fetch
    let primaryPosition = all[0].positions.first(where: {
      $0.instrument == .defaultTestInstrument
    })
    #expect(primaryPosition?.quantity == 1000)
  }

  @Test("rejects empty name")
  func testRejectsEmptyName() async throws {
    let repository = try makeCloudKitAccountRepository()
    let invalidAccount = Account(
      name: "   ",  // Whitespace only
      type: .bank,
      instrument: .defaultTestInstrument
    )

    await #expect(throws: BackendError.self) {
      try await repository.create(invalidAccount, openingBalance: nil)
    }
  }

  @Test("allows negative balance")
  func testAllowsNegativeBalance() async throws {
    let repository = try makeCloudKitAccountRepository()
    let creditCard = Account(
      name: "Credit Card",
      type: .creditCard,
      instrument: .defaultTestInstrument
    )
    let openingBalance = InstrumentAmount(quantity: -500, instrument: .defaultTestInstrument)

    _ = try await repository.create(creditCard, openingBalance: openingBalance)

    let all = try await repository.fetchAll()
    let primaryPosition = all[0].positions.first(where: {
      $0.instrument == .defaultTestInstrument
    })
    #expect(primaryPosition?.quantity == -500)
  }

  // MARK: - UPDATE TESTS

  @Test("updates account name and type")
  func testUpdatesAccount() async throws {
    let repository = try makeCloudKitAccountRepository(initialAccounts: [
      Account(
        id: UUID(), name: "Checking", type: .bank,
        instrument: .defaultTestInstrument)
    ])
    let accounts = try await repository.fetchAll()
    var toUpdate = accounts[0]
    toUpdate.name = "Business Checking"
    toUpdate.type = .asset

    let updated = try await repository.update(toUpdate)

    #expect(updated.name == "Business Checking")
    #expect(updated.type == .asset)
  }

  @Test("preserves balance on update")
  func testPreservesBalance() async throws {
    let repository = try makeCloudKitAccountRepository(
      initialAccounts: [
        Account(
          id: UUID(),
          name: "Savings",
          type: .bank,
          instrument: .defaultTestInstrument
        )
      ],
      openingBalances: [InstrumentAmount(quantity: 1000, instrument: .defaultTestInstrument)]
    )
    let accounts = try await repository.fetchAll()
    var toUpdate = accounts[0]
    toUpdate.name = "Updated Savings"

    let updated = try await repository.update(toUpdate)

    // Balance should be unchanged (server-authoritative)
    let primaryPosition = updated.positions.first(where: {
      $0.instrument == .defaultTestInstrument
    })
    #expect(primaryPosition?.quantity == 1000)
  }

  @Test("throws on update non-existent")
  func testThrowsOnUpdateNonExistent() async throws {
    let repository = try makeCloudKitAccountRepository()
    let nonExistent = Account(
      name: "DoesNotExist", type: .bank, instrument: .defaultTestInstrument)

    await #expect(throws: BackendError.self) {
      try await repository.update(nonExistent)
    }
  }

  // MARK: - DELETE TESTS

  @Test("soft deletes account with zero balance")
  func testDeletesAccountWithZeroBalance() async throws {
    let repository = try makeCloudKitAccountRepository(initialAccounts: [
      Account(
        id: UUID(), name: "Old Account", type: .bank,
        instrument: .defaultTestInstrument)
    ])
    let accounts = try await repository.fetchAll()
    let toDelete = accounts[0]

    try await repository.delete(id: toDelete.id)

    let remaining = try await repository.fetchAll()
    // Account should be marked hidden (soft delete)
    let deleted = remaining.first { $0.id == toDelete.id }
    #expect(deleted != nil)
    #expect(deleted?.isHidden == true)
  }

  @Test("rejects delete with non-zero balance")
  func testRejectsDeleteWithBalance() async throws {
    let repository = try makeCloudKitAccountRepository(
      initialAccounts: [
        Account(
          id: UUID(),
          name: "Active Account",
          type: .bank,
          instrument: .defaultTestInstrument
        )
      ],
      openingBalances: [InstrumentAmount(quantity: 1000, instrument: .defaultTestInstrument)]
    )
    let accounts = try await repository.fetchAll()
    let toDelete = accounts[0]

    await #expect(throws: BackendError.self) {
      try await repository.delete(id: toDelete.id)
    }
  }

  // MARK: - REORDERING TESTS

  // MARK: - Multi-instrument persistence

  @Test("round-trips a USD fiat account with USD opening balance")
  func testRoundTripUSDFiatAccount() async throws {
    let repository = try makeCloudKitAccountRepository()
    let account = Account(name: "US Checking", type: .bank, instrument: .USD)
    let openingBalance = InstrumentAmount(
      quantity: Decimal(string: "750.00")!, instrument: .USD)

    _ = try await repository.create(account, openingBalance: openingBalance)

    let all = try await repository.fetchAll()
    let fetched = try #require(all.first { $0.id == account.id })
    #expect(fetched.instrument == .USD)
    #expect(fetched.instrument.id == "USD")
    #expect(fetched.instrument.kind == .fiatCurrency)
    let usdPosition = fetched.positions.first { $0.instrument == .USD }
    #expect(usdPosition?.quantity == Decimal(string: "750.00")!)
  }

  @Test("round-trips a stock account preserving exchange and ticker")
  func testRoundTripStockAccount() async throws {
    let repository = try makeCloudKitAccountRepository()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = Account(name: "BHP Shares", type: .investment, instrument: bhp)
    let openingBalance = InstrumentAmount(quantity: Decimal(150), instrument: bhp)

    _ = try await repository.create(account, openingBalance: openingBalance)

    let all = try await repository.fetchAll()
    let fetched = try #require(all.first { $0.id == account.id })
    #expect(fetched.instrument == bhp)
    #expect(fetched.instrument.id == "ASX:BHP")
    #expect(fetched.instrument.kind == .stock)
    #expect(fetched.instrument.ticker == "BHP.AX")
    #expect(fetched.instrument.exchange == "ASX")
    let bhpPosition = fetched.positions.first { $0.instrument == bhp }
    #expect(bhpPosition?.quantity == Decimal(150))
  }

  @Test("round-trips a crypto account preserving chainId and contractAddress")
  func testRoundTripCryptoAccount() async throws {
    let repository = try makeCloudKitAccountRepository()
    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6
    )
    let account = Account(name: "Wallet", type: .investment, instrument: usdc)
    let openingBalance = InstrumentAmount(
      quantity: Decimal(string: "2500.000000")!, instrument: usdc)

    _ = try await repository.create(account, openingBalance: openingBalance)

    let all = try await repository.fetchAll()
    let fetched = try #require(all.first { $0.id == account.id })
    #expect(fetched.instrument == usdc)
    #expect(fetched.instrument.kind == .cryptoToken)
    #expect(fetched.instrument.chainId == 1)
    #expect(fetched.instrument.contractAddress == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(fetched.instrument.decimals == 6)
    let position = fetched.positions.first { $0.instrument == usdc }
    #expect(position?.quantity == Decimal(string: "2500.000000")!)
  }

  @Test("accounts with distinct instruments coexist and keep their own instrument")
  func testMultipleAccountsWithDifferentInstruments() async throws {
    let repository = try makeCloudKitAccountRepository()
    let audAccount = Account(
      id: UUID(), name: "AUD Bank", type: .bank, instrument: .AUD)
    let usdAccount = Account(
      id: UUID(), name: "USD Bank", type: .bank, instrument: .USD)
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let stockAccount = Account(
      id: UUID(), name: "Brokerage", type: .investment, instrument: bhp)

    _ = try await repository.create(
      audAccount, openingBalance: InstrumentAmount(quantity: Decimal(1), instrument: .AUD))
    _ = try await repository.create(
      usdAccount, openingBalance: InstrumentAmount(quantity: Decimal(1), instrument: .USD))
    _ = try await repository.create(
      stockAccount, openingBalance: InstrumentAmount(quantity: Decimal(1), instrument: bhp))

    let all = try await repository.fetchAll()
    let aud = try #require(all.first { $0.id == audAccount.id })
    let usd = try #require(all.first { $0.id == usdAccount.id })
    let stock = try #require(all.first { $0.id == stockAccount.id })
    #expect(aud.instrument == .AUD)
    #expect(usd.instrument == .USD)
    #expect(stock.instrument == bhp)
    // Distinct instrument ids ensure records didn't collapse together.
    #expect(Set([aud.instrument.id, usd.instrument.id, stock.instrument.id]).count == 3)
  }

  @Test("updates preserve non-default instrument")
  func testUpdatePreservesNonDefaultInstrument() async throws {
    let repository = try makeCloudKitAccountRepository()
    let account = Account(name: "EUR Wallet", type: .bank, instrument: .fiat(code: "EUR"))
    _ = try await repository.create(account, openingBalance: nil)

    let accounts = try await repository.fetchAll()
    var toUpdate = try #require(accounts.first { $0.id == account.id })
    toUpdate.name = "Renamed EUR Wallet"
    let updated = try await repository.update(toUpdate)

    #expect(updated.instrument.id == "EUR")
    #expect(updated.instrument.kind == .fiatCurrency)
    let refetched = try await repository.fetchAll()
    let final = try #require(refetched.first { $0.id == account.id })
    #expect(final.instrument.id == "EUR")
    #expect(final.name == "Renamed EUR Wallet")
  }

  @Test("updates positions")
  func testUpdatesPositions() async throws {
    let repository = try makeCloudKitWithPositionedAccounts()
    let accounts = try await repository.fetchAll()
    let account1 = accounts.first { $0.name == "First" }!
    let account2 = accounts.first { $0.name == "Second" }!
    let account3 = accounts.first { $0.name == "Third" }!

    // Reorder: move "Third" to first position
    var updated3 = account3
    updated3.position = 0

    var updated1 = account1
    updated1.position = 1

    var updated2 = account2
    updated2.position = 2

    _ = try await repository.update(updated3)
    _ = try await repository.update(updated1)
    _ = try await repository.update(updated2)

    let all = try await repository.fetchAll()
    let sorted = all.sorted()  // Uses position for Comparable

    #expect(sorted[0].name == "Third")
    #expect(sorted[1].name == "First")
    #expect(sorted[2].name == "Second")
  }
}

// MARK: - Factory Helpers

private func makeCloudKitAccountRepository(
  initialAccounts: [Account] = [],
  openingBalances: [InstrumentAmount] = []
) throws -> CloudKitAccountRepository {
  let container = try TestModelContainer.create()
  let instrument = Instrument.defaultTestInstrument
  let repo = CloudKitAccountRepository(
    modelContainer: container)

  if !initialAccounts.isEmpty {
    let context = ModelContext(container)
    for (index, account) in initialAccounts.enumerated() {
      let record = AccountRecord.from(account)
      context.insert(record)
      // If an opening balance is provided for this account, create an opening balance transaction
      let balance = index < openingBalances.count ? openingBalances[index] : nil
      if let balance, !balance.isZero {
        let txnId = UUID()
        let txn = TransactionRecord(id: txnId, date: Date())
        context.insert(txn)
        let leg = TransactionLegRecord.from(
          TransactionLeg(
            accountId: account.id, instrument: instrument,
            quantity: balance.quantity, type: .openingBalance
          ),
          transactionId: txnId, sortOrder: 0
        )
        context.insert(leg)
      }
    }
    try context.save()
  }

  return repo
}

private func makeCloudKitWithPositionedAccounts() throws -> CloudKitAccountRepository {
  let account1 = Account(
    id: UUID(), name: "First", type: .bank, instrument: .defaultTestInstrument,
    position: 0)
  let account2 = Account(
    id: UUID(), name: "Second", type: .bank, instrument: .defaultTestInstrument,
    position: 1)
  let account3 = Account(
    id: UUID(), name: "Third", type: .bank, instrument: .defaultTestInstrument,
    position: 2)
  return try makeCloudKitAccountRepository(initialAccounts: [account1, account2, account3])
}
