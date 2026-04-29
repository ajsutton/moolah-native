// Backends/GRDB/Repositories/GRDBAnalysisRepository.swift

import Foundation
import GRDB
import OSLog

/// GRDB-backed implementation of `AnalysisRepository`. Reads the core
/// financial graph (accounts, transactions, legs, investment values)
/// from `data.sqlite` and reuses the existing per-method computation
/// helpers on `CloudKitAnalysisRepository`. The compute helpers operate
/// on Domain values (`[Transaction]`, `[Account]`, etc.), so the only
/// difference from the SwiftData implementation is where the rows come
/// from.
///
/// **Concurrency.** `final class` + `@unchecked Sendable` rather than
/// `actor`. All stored properties are `let`. `database`
/// (`any DatabaseWriter`) is `Sendable` (GRDB protocol guarantee — the
/// queue's serial executor mediates concurrent access).
/// `conversionService` is itself `Sendable`. Nothing mutates post-init,
/// so the reference can be shared across actor boundaries without a
/// data race.
final class GRDBAnalysisRepository: AnalysisRepository, @unchecked Sendable {
  private let database: any DatabaseWriter
  private let instrument: Instrument
  private let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "GRDBAnalysisRepository")

  init(
    database: any DatabaseWriter,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) {
    self.database = database
    self.instrument = instrument
    self.conversionService = conversionService
  }

  private var analysisContext: CloudKitAnalysisContext {
    CloudKitAnalysisContext(instrument: instrument, conversionService: conversionService)
  }

  // MARK: - AnalysisRepository conformance

  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData {
    let shared = try await fetchSharedData()
    let context = analysisContext

    async let balances = CloudKitAnalysisRepository.computeDailyBalances(
      request: DailyBalancesRequest(
        nonScheduled: shared.nonScheduled,
        scheduled: shared.scheduled,
        accounts: shared.accounts,
        investmentValues: shared.investmentValues,
        after: historyAfter,
        forecastUntil: forecastUntil),
      context: context)
    async let breakdown = CloudKitAnalysisRepository.computeExpenseBreakdown(
      nonScheduled: shared.nonScheduled,
      monthEnd: monthEnd,
      after: historyAfter,
      context: context)
    async let income = CloudKitAnalysisRepository.computeIncomeAndExpense(
      nonScheduled: shared.nonScheduled,
      accounts: shared.accounts,
      monthEnd: monthEnd,
      after: historyAfter,
      context: context)

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income)
  }

  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    let shared = try await fetchSharedData()
    return try await CloudKitAnalysisRepository.computeDailyBalances(
      request: DailyBalancesRequest(
        nonScheduled: shared.nonScheduled,
        scheduled: shared.scheduled,
        accounts: shared.accounts,
        investmentValues: shared.investmentValues,
        after: after,
        forecastUntil: forecastUntil),
      context: analysisContext)
  }

  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown] {
    let nonScheduled = try await fetchTransactions(filter: .nonScheduledOnly)
    return try await CloudKitAnalysisRepository.computeExpenseBreakdown(
      nonScheduled: nonScheduled,
      monthEnd: monthEnd,
      after: after,
      context: analysisContext)
  }

  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    let nonScheduled = try await fetchTransactions(filter: .nonScheduledOnly)
    let accounts = try await fetchAccounts()
    return try await CloudKitAnalysisRepository.computeIncomeAndExpense(
      nonScheduled: nonScheduled,
      accounts: accounts,
      monthEnd: monthEnd,
      after: after,
      context: analysisContext)
  }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> [UUID: InstrumentAmount] {
    let allTransactions = try await fetchTransactions(filter: .all)
    var balances: [UUID: InstrumentAmount] = [:]
    let query = CategoryBalancesQuery(
      dateRange: dateRange,
      transactionType: transactionType,
      filters: filters,
      targetInstrument: targetInstrument,
      conversionService: conversionService)
    for transaction in allTransactions {
      guard query.shouldInclude(transaction) else { continue }
      try await query.accumulate(transaction: transaction, into: &balances)
    }
    return balances
  }

  // MARK: - Shared data load (GRDB)

  private struct SharedData: Sendable {
    let nonScheduled: [Transaction]
    let scheduled: [Transaction]
    let accounts: [Account]
    let investmentValues: [InvestmentValueSnapshot]
  }

  private func fetchSharedData() async throws -> SharedData {
    let allTransactions = try await fetchTransactions(filter: .all)
    let accounts = try await fetchAccounts()
    let nonScheduled = allTransactions.filter { !$0.isScheduled }
    let scheduled = allTransactions.filter { $0.isScheduled }
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))
    let investmentValues = try await fetchAllInvestmentValues(
      investmentAccountIds: investmentAccountIds)
    return SharedData(
      nonScheduled: nonScheduled,
      scheduled: scheduled,
      accounts: accounts,
      investmentValues: investmentValues)
  }

  private func fetchTransactions(filter: ScheduledFilter) async throws -> [Transaction] {
    try await database.read { database -> [Transaction] in
      let txnRows = try TransactionRow.fetchAll(database)
      let legRows = try TransactionLegRow.fetchAll(database)
      let instrumentRows = try InstrumentRow.fetchAll(database)

      var instrumentLookup: [String: Instrument] = [:]
      for row in instrumentRows {
        instrumentLookup[row.id] = row.toDomain()
      }

      let legsByTxnId = Dictionary(grouping: legRows, by: \.transactionId)

      var transactions = txnRows.map { row -> Transaction in
        let legs =
          (legsByTxnId[row.id] ?? [])
          .sorted { $0.sortOrder < $1.sortOrder }
          .map { legRow -> TransactionLeg in
            let legInstrument =
              instrumentLookup[legRow.instrumentId]
              ?? Instrument.fiat(code: legRow.instrumentId)
            return legRow.toDomain(instrument: legInstrument)
          }
        return row.toDomain(legs: legs)
      }

      switch filter {
      case .all:
        return transactions
      case .scheduledOnly:
        transactions = transactions.filter(\.isScheduled)
      case .nonScheduledOnly:
        transactions = transactions.filter { !$0.isScheduled }
      }
      return transactions
    }
  }

  private func fetchAccounts() async throws -> [Account] {
    let resolvedInstrument = self.instrument
    return try await database.read { database -> [Account] in
      let rows = try AccountRow.fetchAll(database)
      return rows.map { row in
        Account(
          id: row.id,
          name: row.name,
          type: AccountType(rawValue: row.type) ?? .bank,
          instrument: resolvedInstrument,
          position: row.position,
          isHidden: row.isHidden)
      }
    }
  }

  private func fetchAllInvestmentValues(
    investmentAccountIds: Set<UUID>
  ) async throws -> [InvestmentValueSnapshot] {
    guard !investmentAccountIds.isEmpty else { return [] }
    return try await database.read { database -> [InvestmentValueSnapshot] in
      let rows =
        try InvestmentValueRow
        .filter(investmentAccountIds.contains(InvestmentValueRow.Columns.accountId))
        .fetchAll(database)
      return
        rows
        .map { row -> InvestmentValueSnapshot in
          let value = row.toDomain().value
          return InvestmentValueSnapshot(
            accountId: row.accountId,
            date: row.date,
            value: value)
        }
        .sorted { $0.date < $1.date }
    }
  }
}

// MARK: - Local copy of the shared category-balances accumulator

extension GRDBAnalysisRepository {
  /// Mirror of `CloudKitAnalysisRepository.CategoryBalancesQuery`. Local
  /// copy so this implementation does not depend on the CloudKit repo's
  /// nested types beyond the static compute helpers.
  private struct CategoryBalancesQuery: Sendable {
    let dateRange: ClosedRange<Date>
    let transactionType: TransactionType
    let filters: TransactionFilter?
    let targetInstrument: Instrument
    let conversionService: any InstrumentConversionService

    func shouldInclude(_ transaction: Transaction) -> Bool {
      guard dateRange.contains(transaction.date) else { return false }
      guard transaction.recurPeriod == nil else { return false }
      if let accountId = filters?.accountId,
        !transaction.accountIds.contains(accountId)
      {
        return false
      }
      if let payee = filters?.payee, transaction.payee != payee {
        return false
      }
      return true
    }

    func accumulate(
      transaction: Transaction,
      into balances: inout [UUID: InstrumentAmount]
    ) async throws {
      for leg in transaction.legs {
        guard leg.type == transactionType else { continue }
        guard let categoryId = leg.categoryId else { continue }
        if let earmarkId = filters?.earmarkId, leg.earmarkId != earmarkId {
          continue
        }
        if let categoryIds = filters?.categoryIds, !categoryIds.isEmpty,
          !categoryIds.contains(categoryId)
        {
          continue
        }
        let amount = try await CloudKitAnalysisRepository.convertedAmount(
          leg,
          to: targetInstrument,
          on: transaction.date,
          conversionService: conversionService)
        balances[categoryId, default: .zero(instrument: targetInstrument)] += amount
      }
    }
  }
}
