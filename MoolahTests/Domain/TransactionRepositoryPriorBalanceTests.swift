import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionRepository — priorBalance")
struct TransactionRepositoryPriorBalanceTests {
  @Test("priorBalance is sum of transactions before the page")
  func testPriorBalanceAcrossPages() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makePaginationContractTestTransactions())
    let accountFilter = TransactionFilter(
      accountId: TransactionContractTestFixtures.paginationAccountId)
    let page0 = try await repository.fetch(
      filter: accountFilter,
      page: 0,
      pageSize: 2
    )

    let page1 = try await repository.fetch(
      filter: accountFilter,
      page: 1,
      pageSize: 2
    )

    // priorBalance for page 0 should be sum of transactions on page 1+
    let page1Sum = page1.transactions.reduce(
      InstrumentAmount.zero(instrument: .defaultTestInstrument)
    ) {
      $0
        + $1.legs.reduce(InstrumentAmount.zero(instrument: .defaultTestInstrument)) {
          $0 + $1.amount
        }
    }
    let page1Prior = try #require(page1.priorBalance)
    let page1PriorSum = page1Sum + page1Prior
    let page0Prior = try #require(page0.priorBalance)

    #expect(
      page0Prior == page1PriorSum,
      "priorBalance of page 0 should equal sum of all older transactions")
  }

  @Test("empty page returns zero priorBalance")
  func testEmptyPagePriorBalance() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makePaginationContractTestTransactions())
    let page = try await repository.fetch(
      filter: TransactionFilter(),
      page: 100,
      pageSize: 10
    )

    #expect(page.transactions.isEmpty)
    let prior = try #require(page.priorBalance)
    #expect(prior.isZero)
  }

  @Test("priorBalance is labelled with the account's own instrument")
  func testPriorBalanceUsesAccountInstrument() async throws {
    // Non-profile instrument for the viewing account.
    let accountInstrument = Instrument.USD
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: accountId, name: "USD Account", type: .bank, instrument: accountInstrument)
    TestBackend.seed(
      accounts: [(account, InstrumentAmount.zero(instrument: accountInstrument))],
      in: database)
    // Two transactions in the USD account so we need a priorBalance across pages.
    let ten = try #require(Decimal(string: "10"))
    let twenty = try #require(Decimal(string: "20"))
    let tx1 = Transaction(
      date: Date(timeIntervalSince1970: 1),
      payee: "Older",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: ten, type: .income)
      ])
    let tx2 = Transaction(
      date: Date(timeIntervalSince1970: 2),
      payee: "Newer",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: twenty, type: .income)
      ])
    TestBackend.seed(transactions: [tx1, tx2], in: database)

    // Page size of 1 forces a non-zero priorBalance on page 0.
    let page0 = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 1)
    #expect(page0.targetInstrument == accountInstrument)

    // Empty paged-past-end response should also use the account's instrument.
    let pageN = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 99, pageSize: 1)
    #expect(pageN.targetInstrument == accountInstrument)
  }

  @Test("priorBalance converts multi-instrument legs to account instrument at today's rate")
  func testPriorBalanceMultiInstrumentConverts() async throws {
    // Account is AUD. Historic transactions left three legs behind (one still
    // in a different instrument) — a trade-style split.
    let accountInstrument = Instrument.AUD
    let foreignInstrument = Instrument.USD
    let accountId = UUID()

    // USD -> AUD at 1.5 today. FixedRateClient keys are ISO-8601 date →
    // quote-currency rates (base is passed separately to fetchRates).
    let todayFormatter = ISO8601DateFormatter()
    todayFormatter.formatOptions = [.withFullDate]
    let todayKey = todayFormatter.string(from: Date())
    let audRate = try #require(Decimal(string: "1.5"))
    let rates: [String: [String: Decimal]] = [
      todayKey: ["AUD": audRate]
    ]
    let (backend, database) = try TestBackend.create(
      instrument: accountInstrument, exchangeRates: rates)
    let account = Account(
      id: accountId, name: "Brokerage", type: .bank, instrument: accountInstrument)
    TestBackend.seed(
      accounts: [(account, InstrumentAmount.zero(instrument: accountInstrument))],
      in: database)

    // Two older transactions (will be on page 1+, contributing to priorBalance).
    // tx1: AUD +100 (cash deposit)
    let tx1 = Transaction(
      date: Date(timeIntervalSince1970: 1_000_000),
      payee: "Cash in",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(100), type: .income)
      ])
    // tx2: USD +20 (foreign cash in — will be converted @ 1.5 = +30 AUD today)
    let tx2 = Transaction(
      date: Date(timeIntervalSince1970: 1_000_001),
      payee: "Foreign in",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: foreignInstrument,
          quantity: Decimal(20), type: .income)
      ])
    // tx3 (newest): a single page-0 entry so priorBalance covers tx1+tx2.
    let tx3 = Transaction(
      date: Date(timeIntervalSince1970: 2_000_000),
      payee: "Today",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(5), type: .income)
      ])
    TestBackend.seed(transactions: [tx1, tx2, tx3], in: database)

    // pageSize: 1 => page 0 has only tx3; priorBalance = tx1 + tx2(USD->AUD).
    let page0 = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 1)

    let prior = try #require(page0.priorBalance)
    #expect(prior.instrument == accountInstrument)
    // 100 AUD + 20 USD @ 1.5 = 130 AUD.
    #expect(prior == InstrumentAmount(quantity: Decimal(130), instrument: accountInstrument))
    #expect(page0.targetInstrument == accountInstrument)
  }

  @Test("priorBalance is nil when conversion fails for any foreign leg")
  func testPriorBalanceNilOnConversionFailure() async throws {
    // Account AUD; historic leg is in an unsupported pair (no rate provided).
    let accountInstrument = Instrument.AUD
    let foreignInstrument = Instrument.USD
    let accountId = UUID()
    // Empty rate table => USD->AUD lookup fails.
    let (backend, database) = try TestBackend.create(
      instrument: accountInstrument, exchangeRates: [:])
    let account = Account(
      id: accountId, name: "Brokerage", type: .bank, instrument: accountInstrument)
    TestBackend.seed(
      accounts: [(account, InstrumentAmount.zero(instrument: accountInstrument))],
      in: database)

    let tx1 = Transaction(
      date: Date(timeIntervalSince1970: 1_000_000),
      payee: "Foreign in",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: foreignInstrument,
          quantity: Decimal(20), type: .income)
      ])
    let tx2 = Transaction(
      date: Date(timeIntervalSince1970: 2_000_000),
      payee: "Today",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(5), type: .income)
      ])
    TestBackend.seed(transactions: [tx1, tx2], in: database)

    let page0 = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 1)

    #expect(page0.priorBalance == nil, "conversion failure should null the prior balance")
    #expect(page0.targetInstrument == accountInstrument)
    // Transactions still flow through — failure degrades gracefully.
    #expect(page0.transactions.count == 1)
  }

  @Test("priorBalance skips conversion when all legs share the account instrument")
  func testPriorBalanceSingleInstrumentNoConversionNeeded() async throws {
    // Empty rate table: if conversion were invoked it would throw. Test asserts
    // the same-instrument short-circuit keeps working.
    let accountInstrument = Instrument.AUD
    let accountId = UUID()
    let (backend, database) = try TestBackend.create(
      instrument: accountInstrument, exchangeRates: [:])
    let account = Account(
      id: accountId, name: "Bank", type: .bank, instrument: accountInstrument)
    TestBackend.seed(
      accounts: [(account, InstrumentAmount.zero(instrument: accountInstrument))],
      in: database)

    let tx1 = Transaction(
      date: Date(timeIntervalSince1970: 1_000_000),
      payee: "Older",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(50), type: .income)
      ])
    let tx2 = Transaction(
      date: Date(timeIntervalSince1970: 2_000_000),
      payee: "Newer",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(25), type: .income)
      ])
    TestBackend.seed(transactions: [tx1, tx2], in: database)

    let page0 = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 1)

    let prior = try #require(page0.priorBalance)
    #expect(prior == InstrumentAmount(quantity: Decimal(50), instrument: accountInstrument))
  }
}
