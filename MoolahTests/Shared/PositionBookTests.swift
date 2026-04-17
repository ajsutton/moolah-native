import Foundation
import Testing

@testable import Moolah

@Suite("PositionBook Tests")
struct PositionBookTests {

  // MARK: - Test Helpers

  private let bankAccount = UUID()
  private let bankAccount2 = UUID()
  private let investmentAccount = UUID()
  private let earmarkA = UUID()
  private let earmarkB = UUID()
  private let aud = Instrument.AUD
  private let usd = Instrument.USD
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func transaction(
    id: UUID = UUID(),
    date: Date? = nil,
    legs: [TransactionLeg]
  ) -> Transaction {
    Transaction(id: id, date: date ?? self.date, legs: legs)
  }

  // MARK: - Empty / Apply

  @Test("empty book has no positions")
  func emptyBookHasNoPositions() {
    let book = PositionBook.empty
    #expect(book.accounts.isEmpty)
    #expect(book.earmarks.isEmpty)
    #expect(book.earmarksSaved.isEmpty)
    #expect(book.earmarksSpent.isEmpty)
    #expect(book.accountsFromTransfers.isEmpty)
    #expect(book == PositionBook())
  }

  @Test("applying a single-leg transaction records the position")
  func applySingleLegRecordsPosition() {
    var book = PositionBook.empty
    let leg = TransactionLeg(
      accountId: bankAccount, instrument: aud, quantity: -50, type: .expense,
      earmarkId: earmarkA)
    book.apply(transaction(legs: [leg]))

    #expect(book.accounts[bankAccount]?[aud] == -50)
    #expect(book.earmarks[earmarkA]?[aud] == -50)
    #expect(book.earmarksSpent[earmarkA]?[aud] == 50)
    #expect(book.earmarksSaved.isEmpty)
    #expect(book.accountsFromTransfers.isEmpty)
  }

  @Test("applying a transaction records all its legs")
  func applyTransactionRecordsAllLegs() {
    var book = PositionBook.empty
    let txn = transaction(legs: [
      TransactionLeg(accountId: bankAccount, instrument: aud, quantity: -200, type: .transfer),
      TransactionLeg(accountId: bankAccount2, instrument: aud, quantity: 200, type: .transfer),
    ])
    book.apply(txn)

    #expect(book.accounts[bankAccount]?[aud] == -200)
    #expect(book.accounts[bankAccount2]?[aud] == 200)
  }

  @Test("sign = -1 reverses an application")
  func signMinusOneReverses() {
    var book = PositionBook.empty
    let txn = transaction(legs: [
      TransactionLeg(
        accountId: bankAccount, instrument: aud, quantity: 100, type: .income,
        earmarkId: earmarkA)
    ])
    book.apply(txn, sign: 1)
    book.apply(txn, sign: -1)
    book.cleanZeros()

    #expect(book == PositionBook.empty)
  }

  @Test("applying old-sign-negative then new-sign-positive matches BalanceDeltaCalculator")
  func matchesBalanceDeltaCalculator() {
    let txId = UUID()
    let oldTxn = transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: bankAccount, instrument: aud, quantity: -50, type: .expense,
          earmarkId: earmarkA)
      ])
    let newTxn = transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: bankAccount, instrument: aud, quantity: -80, type: .expense,
          earmarkId: earmarkB),
        TransactionLeg(
          accountId: bankAccount2, instrument: usd, quantity: 30, type: .income,
          earmarkId: earmarkA),
      ])

    var book = PositionBook.empty
    book.apply(oldTxn, sign: -1)
    book.apply(newTxn, sign: 1)
    book.cleanZeros()

    let delta = BalanceDeltaCalculator.deltas(old: oldTxn, new: newTxn)

    #expect(book.accounts == delta.accountDeltas)
    #expect(book.earmarks == delta.earmarkDeltas)
    #expect(book.earmarksSaved == delta.earmarkSavedDeltas)
    #expect(book.earmarksSpent == delta.earmarkSpentDeltas)
  }

  // MARK: - cleanZeros

  @Test("cleanZeros removes zero-valued instruments and empty entities")
  func cleanZerosRemovesEmpty() {
    var book = PositionBook.empty
    let txn = transaction(legs: [
      TransactionLeg(accountId: bankAccount, instrument: aud, quantity: 100, type: .income)
    ])
    book.apply(txn, sign: 1)
    book.apply(txn, sign: -1)

    // Pre-clean: zero entry exists.
    #expect(book.accounts[bankAccount]?[aud] == 0)

    book.cleanZeros()

    #expect(book.accounts.isEmpty)
  }

  // MARK: - dailyBalance — single instrument

  @Test("single-instrument dailyBalance returns raw quantities without conversion")
  func singleInstrumentDailyBalanceSkipsConversion() async throws {
    var book = PositionBook.empty
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount, instrument: aud, quantity: 1_000, type: .income)
      ]))
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount, instrument: aud, quantity: -150, type: .expense)
      ]))

    // Tuned with a non-1 USD rate to prove the fast path is taken: if the
    // conversion service were called, totals would change.
    let conversion = FixedConversionService(rates: ["USD": 999])

    let result = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [],
      profileInstrument: aud,
      rule: .allLegs,
      conversionService: conversion,
      isForecast: false
    )

    #expect(result.balance.quantity == 850)
    #expect(result.balance.instrument == aud)
    #expect(result.investments.quantity == 0)
    #expect(result.earmarked.quantity == 0)
    #expect(result.availableFunds.quantity == 850)
    #expect(result.netWorth.quantity == 850)
    #expect(result.investmentValue == nil)
    #expect(result.bestFit == nil)
    #expect(result.isForecast == false)
  }

  // MARK: - dailyBalance — multi instrument

  @Test("multi-instrument dailyBalance converts at the given date's rates")
  func multiInstrumentDailyBalanceConverts() async throws {
    var book = PositionBook.empty
    // 100 AUD in bank account.
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount, instrument: aud, quantity: 100, type: .income)
      ]))
    // 50 USD in another bank account — should be converted at 1.5 AUD/USD = 75 AUD.
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount2, instrument: usd, quantity: 50, type: .income)
      ]))

    let conversion = FixedConversionService(rates: ["USD": 1.5])

    let result = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [],
      profileInstrument: aud,
      rule: .allLegs,
      conversionService: conversion,
      isForecast: false
    )

    // 100 AUD + (50 USD × 1.5) = 175 AUD
    #expect(result.balance.quantity == 175)
    #expect(result.balance.instrument == aud)
  }

  // MARK: - dailyBalance — earmarks

  @Test("earmarks are per-earmark clamped to zero before summing")
  func earmarksClampedPerEarmark() async throws {
    var book = PositionBook.empty
    // earmarkA: -200 (negative — should be clamped to 0).
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: bankAccount, instrument: aud, quantity: -200, type: .expense,
          earmarkId: earmarkA)
      ]))
    // earmarkB: +500 (positive — counted in full).
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: bankAccount, instrument: aud, quantity: 500, type: .income,
          earmarkId: earmarkB)
      ]))

    let conversion = FixedConversionService()

    let result = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [],
      profileInstrument: aud,
      rule: .allLegs,
      conversionService: conversion,
      isForecast: false
    )

    // earmarkA clamped to 0, earmarkB contributes 500, total = 500.
    // (Naive sum without clamping would be -200 + 500 = 300.)
    #expect(result.earmarked.quantity == 500)
  }

  // MARK: - dailyBalance — investment rules

  @Test("allLegs rule sums all investment-account positions")
  func allLegsRuleSumsAllInvestmentPositions() async throws {
    var book = PositionBook.empty
    // Transfer into investment account.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 1_000, type: .transfer)
      ]),
      investmentAccountIds: [investmentAccount])
    // Expense (e.g. capital loss / fee) on investment account.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: -50, type: .expense)
      ]),
      investmentAccountIds: [investmentAccount])

    let conversion = FixedConversionService()

    let result = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [investmentAccount],
      profileInstrument: aud,
      rule: .allLegs,
      conversionService: conversion,
      isForecast: false
    )

    // .allLegs sees the full position: 1000 - 50 = 950.
    #expect(result.investments.quantity == 950)
    #expect(result.balance.quantity == 0)
  }

  @Test("investmentTransfersOnly rule sums only transfer-derived positions")
  func investmentTransfersOnlyRule() async throws {
    var book = PositionBook.empty
    // Transfer into investment account: contributes to both dicts.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 1_000, type: .transfer)
      ]),
      investmentAccountIds: [investmentAccount])
    // Income on investment account: contributes only to `accounts`.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 200, type: .income)
      ]),
      investmentAccountIds: [investmentAccount])

    let conversion = FixedConversionService()

    let result = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [investmentAccount],
      profileInstrument: aud,
      rule: .investmentTransfersOnly,
      conversionService: conversion,
      isForecast: false
    )

    // Only the transfer counts: 1000.
    #expect(result.investments.quantity == 1_000)
  }

  @Test("investment-account expense leg does not inflate transfers-only total")
  func expenseDoesNotInflateTransfersOnly() async throws {
    var book = PositionBook.empty
    // No transfers — only an expense on the investment account.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: -100, type: .expense)
      ]),
      investmentAccountIds: [investmentAccount])

    let conversion = FixedConversionService()

    let result = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [investmentAccount],
      profileInstrument: aud,
      rule: .investmentTransfersOnly,
      conversionService: conversion,
      isForecast: false
    )

    // Expense leg never reaches accountsFromTransfers; investments total is 0.
    #expect(result.investments.quantity == 0)
    #expect(book.accountsFromTransfers.isEmpty)
  }

  // MARK: - apply(_:asStartingBalance:)

  @Test("apply with asStartingBalance: true records non-transfer investment legs in transfers")
  func startingBalanceRecordsNonTransferInvestmentLegs() async throws {
    var book = PositionBook.empty
    // Income on investment account, applied as a starting balance.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 700, type: .income)
      ]),
      investmentAccountIds: [investmentAccount],
      asStartingBalance: true)
    // Opening balance on investment account, applied as a starting balance.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 300,
          type: .openingBalance)
      ]),
      investmentAccountIds: [investmentAccount],
      asStartingBalance: true)

    // Both legs land in `accountsFromTransfers` because asStartingBalance == true.
    #expect(book.accountsFromTransfers[investmentAccount]?[aud] == 1_000)
    #expect(book.accounts[investmentAccount]?[aud] == 1_000)

    let conversion = FixedConversionService()
    let result = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [investmentAccount],
      profileInstrument: aud,
      rule: .investmentTransfersOnly,
      conversionService: conversion,
      isForecast: false
    )
    // .investmentTransfersOnly read sees the seeded baseline.
    #expect(result.investments.quantity == 1_000)
  }

  @Test("apply with asStartingBalance: false (default) leaves non-transfer investment legs out")
  func startingBalanceFalseExcludesNonTransferInvestmentLegs() {
    var book = PositionBook.empty
    // Default behaviour: only .transfer legs on investment accounts contribute
    // to accountsFromTransfers. An income leg on the investment account must
    // NOT appear in that dict.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 200, type: .income)
      ]),
      investmentAccountIds: [investmentAccount])

    #expect(book.accounts[investmentAccount]?[aud] == 200)
    #expect(book.accountsFromTransfers.isEmpty)
  }

  @Test(
    "apply with asStartingBalance: true is a no-op for accountsFromTransfers when no investment accounts"
  )
  func startingBalanceNoInvestmentAccountsIsNoOp() {
    var book = PositionBook.empty
    // Bank-only transaction with no investment accounts at all.
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount, instrument: aud, quantity: 500, type: .income)
      ]),
      investmentAccountIds: [],
      asStartingBalance: true)

    #expect(book.accounts[bankAccount]?[aud] == 500)
    #expect(book.accountsFromTransfers.isEmpty)
  }

  @Test("investment-account transfer leg appears in both all-legs and transfers-only")
  func transferAppearsInBothRules() async throws {
    var book = PositionBook.empty
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 500, type: .transfer)
      ]),
      investmentAccountIds: [investmentAccount])

    let conversion = FixedConversionService()

    let allLegs = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [investmentAccount],
      profileInstrument: aud,
      rule: .allLegs,
      conversionService: conversion,
      isForecast: false
    )
    let transfersOnly = try await book.dailyBalance(
      on: date,
      investmentAccountIds: [investmentAccount],
      profileInstrument: aud,
      rule: .investmentTransfersOnly,
      conversionService: conversion,
      isForecast: false
    )

    #expect(allLegs.investments.quantity == 500)
    #expect(transfersOnly.investments.quantity == 500)
  }
}
