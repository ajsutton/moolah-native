import Foundation
import GRDB
import OSLog

/// GRDB-backed implementation of `AnalysisRepository`. Reads the core
/// financial graph (accounts, transactions, legs, investment values)
/// from `data.sqlite`. `fetchExpenseBreakdown` runs a SQL aggregation
/// (`+ExpenseBreakdown.swift`) and converts each `(day, category,
/// instrument)` tuple in Swift; the remaining methods still materialise
/// every row and reuse the per-method compute helpers on
/// `CloudKitAnalysisRepository` until the remaining SQL rewrites land.
///
/// **Concurrency.** `final class` + `@unchecked Sendable` rather than
/// `actor`. All stored properties are `let`. `database`
/// (`any DatabaseWriter`) is `Sendable` (GRDB protocol guarantee — the
/// queue's serial executor mediates concurrent access).
/// `conversionService` is itself `Sendable`. `logger` is `OSLog.Logger`,
/// also `Sendable` (Apple-documented thread-safe value type). Nothing
/// mutates post-init, so the reference can be shared across actor
/// boundaries without a data race.
final class GRDBAnalysisRepository: AnalysisRepository, @unchecked Sendable {
  // MARK: - Cross-extension internals
  // The following are stored / static state shared with sibling-file
  // extensions:
  //
  // `+Conversion.swift` — `parseDayString`, `financialMonth`,
  // `convertedQuantity`. Free of stored-state coupling; takes its
  // dependencies as parameters.
  //
  // `+ExpenseBreakdown.swift` — `fetchExpenseBreakdownAggregation`,
  // `assembleExpenseBreakdown`, `ExpenseBreakdownRow`,
  // `ExpenseBreakdownAggregation`, `ExpenseBreakdownHandlers`. Also
  // free of stored-state coupling.
  //
  // `+CategoryBalances.swift` — `fetchCategoryBalancesAggregation`,
  // `assembleCategoryBalances`, `CategoryBalancesRow`,
  // `CategoryBalancesAggregation`, `CategoryBalancesHandlers`,
  // `CategoryBalancesFilterArgs`. Same shape as `+ExpenseBreakdown`.
  //
  // `+IncomeAndExpense.swift` — types (`IncomeAndExpenseRow`,
  // `IncomeAndExpenseAggregation`, `IncomeAndExpenseHandlers`,
  // `IncomeAndExpenseFailureContext`), `assembleIncomeAndExpense`, and
  // private helpers (`convertRowSums`, `makeEmptyMonthBucket`,
  // `applyConvertedRow`, `flattenIncomeAndExpenseBuckets`).
  //
  // `+IncomeAndExpenseAggregation.swift` — `fetchIncomeAndExpenseAggregation`,
  // `mapAggregationRow`, file-private `incomeAndExpenseAggregationSQL`.
  // Split out of `+IncomeAndExpense.swift` for `file_length` budget.
  //
  // `database` and `logger` are read by `fetchExpenseBreakdown`,
  // `fetchCategoryBalances`, and `fetchIncomeAndExpense` here in the
  // main file; the sibling extensions pull them through the call site
  // rather than reaching into `private` storage from another file.
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
    async let breakdown = fetchExpenseBreakdown(monthEnd: monthEnd, after: historyAfter)
    async let income = fetchIncomeAndExpense(monthEnd: monthEnd, after: historyAfter)

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
    let aggregation = try await Self.fetchExpenseBreakdownAggregation(
      database: database, after: after)
    let logger = self.logger
    let handlers = ExpenseBreakdownHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchExpenseBreakdown: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        logger.error(
          """
          fetchExpenseBreakdown: conversion failed for day=\(context.day, privacy: .public) \
          category=\(context.categoryId?.uuidString ?? "nil", privacy: .public) \
          instrument=\(context.instrumentId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      })
    return try await Self.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: instrument,
      conversionService: conversionService,
      monthEnd: monthEnd,
      handlers: handlers)
  }

  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    let aggregation = try await Self.fetchIncomeAndExpenseAggregation(
      database: database, after: after)
    let logger = self.logger
    let handlers = IncomeAndExpenseHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchIncomeAndExpense: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        logger.error(
          """
          fetchIncomeAndExpense: conversion failed for day=\(context.day, privacy: .public) \
          instrument=\(context.instrumentId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      })
    return try await Self.assembleIncomeAndExpense(
      aggregation: aggregation,
      profileInstrument: instrument,
      conversionService: conversionService,
      monthEnd: monthEnd,
      handlers: handlers)
  }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> [UUID: InstrumentAmount] {
    let args = CategoryBalancesFilterArgs(
      dateRange: dateRange,
      transactionType: transactionType,
      accountId: filters?.accountId,
      earmarkId: filters?.earmarkId,
      payee: filters?.payee,
      categoryIds: filters?.categoryIds ?? [])
    let aggregation = try await Self.fetchCategoryBalancesAggregation(
      database: database, args: args)
    let logger = self.logger
    let handlers = CategoryBalancesHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchCategoryBalances: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        logger.error(
          """
          fetchCategoryBalances: conversion failed for day=\(context.day, privacy: .public) \
          category=\(context.categoryId, privacy: .public) \
          instrument=\(context.instrumentId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      })
    return try await Self.assembleCategoryBalances(
      aggregation: aggregation,
      targetInstrument: targetInstrument,
      conversionService: conversionService,
      handlers: handlers)
  }

  // MARK: - Shared data load (GRDB)

  private struct SharedData: Sendable {
    let nonScheduled: [Transaction]
    let scheduled: [Transaction]
    let accounts: [Account]
    let investmentValues: [InvestmentValueSnapshot]
  }

  /// Loads transactions, accounts, and investment values in a single
  /// `database.read` so every value comes from the same MVCC snapshot.
  /// Three independent reads under WAL would race a concurrent writer
  /// and surface internally inconsistent state — e.g. a leg referencing
  /// an account that hasn't yet appeared in the account list.
  private func fetchSharedData() async throws -> SharedData {
    let resolvedInstrument = self.instrument
    return try await database.read { database -> SharedData in
      let allTransactions = try Self.fetchTransactionsSnapshot(
        filter: .all, database: database)
      let accounts = try Self.fetchAccountsSnapshot(
        database: database, instrument: resolvedInstrument)
      let nonScheduled = allTransactions.filter { !$0.isScheduled }
      let scheduled = allTransactions.filter { $0.isScheduled }
      let investmentAccountIds = Set(
        accounts.filter { $0.type == .investment }.map(\.id))
      let investmentValues = try Self.fetchAllInvestmentValuesSnapshot(
        database: database, investmentAccountIds: investmentAccountIds)
      return SharedData(
        nonScheduled: nonScheduled,
        scheduled: scheduled,
        accounts: accounts,
        investmentValues: investmentValues)
    }
  }

  /// Loads every transaction (and its legs) as Domain values.
  ///
  /// **Intentional full table scan.** This method drives the analysis
  /// hot paths and currently materialises every row in `transaction`,
  /// `transaction_leg`, and `instrument` so the existing Swift-side
  /// compute helpers can run unchanged. The four covering indexes
  /// (`leg_analysis_by_type_account`, `leg_analysis_by_type_category`,
  /// `leg_analysis_by_earmark_type`, `iv_by_account_date_value`) are
  /// in place but not yet exploited from this path — TODO(#577) pushes
  /// the per-instrument GROUP BY into SQL and removes the SCAN —
  /// https://github.com/ajsutton/moolah-native/issues/577
  private func fetchTransactions(filter: ScheduledFilter) async throws -> [Transaction] {
    try await database.read { database -> [Transaction] in
      try Self.fetchTransactionsSnapshot(filter: filter, database: database)
    }
  }

  private static func fetchTransactionsSnapshot(
    filter: ScheduledFilter, database: Database
  ) throws -> [Transaction] {
    let txnRows = try TransactionRow.fetchAll(database)
    let legRows = try TransactionLegRow.fetchAll(database)
    let instrumentRows = try InstrumentRow.fetchAll(database)

    var instrumentLookup: [String: Instrument] = [:]
    for row in instrumentRows {
      instrumentLookup[row.id] = try row.toDomain()
    }

    let legsByTxnId = Dictionary(grouping: legRows, by: \.transactionId)

    var transactions = try txnRows.map { row -> Transaction in
      let legs =
        try (legsByTxnId[row.id] ?? [])
        .sorted { $0.sortOrder < $1.sortOrder }
        .map { legRow -> TransactionLeg in
          let legInstrument =
            instrumentLookup[legRow.instrumentId]
            ?? Instrument.fiat(code: legRow.instrumentId)
          return try legRow.toDomain(instrument: legInstrument)
        }
      return try row.toDomain(legs: legs)
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

  private func fetchAccounts() async throws -> [Account] {
    let resolvedInstrument = self.instrument
    return try await database.read { database -> [Account] in
      try Self.fetchAccountsSnapshot(database: database, instrument: resolvedInstrument)
    }
  }

  private static func fetchAccountsSnapshot(
    database: Database, instrument: Instrument
  ) throws -> [Account] {
    let rows = try AccountRow.fetchAll(database)
    return try rows.map { row in
      Account(
        id: row.id,
        name: row.name,
        type: try AccountType.decoded(rawValue: row.type),
        instrument: instrument,
        position: row.position,
        isHidden: row.isHidden)
    }
  }

  private static func fetchAllInvestmentValuesSnapshot(
    database: Database,
    investmentAccountIds: Set<UUID>
  ) throws -> [InvestmentValueSnapshot] {
    guard !investmentAccountIds.isEmpty else { return [] }
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
