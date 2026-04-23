import Foundation
import OSLog
import SwiftData

// internal (was private) so sibling extension files can emit the same
// warnings using the shared subsystem/category.
let analysisLogger = Logger(
  subsystem: "com.moolah.app", category: "CloudKitAnalysisRepository")

/// Filter applied to `CloudKitAnalysisRepository.fetchTransactions`.
///
/// Replaces a tri-state `Bool?` parameter — `nil` meant "all", `true` meant
/// "scheduled only", `false` meant "non-scheduled only". Using an enum makes
/// the intent readable at call sites and satisfies SwiftLint's
/// `discouraged_optional_boolean` rule.
enum ScheduledFilter {
  case all
  case scheduledOnly
  case nonScheduledOnly
}

/// Shared parameters threaded through the off-main static computation path.
///
/// Bundles the profile instrument + conversion service that every static
/// compute function needs, so we stay under SwiftLint's 5-param threshold and
/// avoid repeating the same two trailing arguments everywhere.
struct CloudKitAnalysisContext: Sendable {
  let instrument: Instrument
  let conversionService: any InstrumentConversionService
}

/// Helper struct for building monthly data (prefixed to avoid collision with
/// InMemory version). internal (was private) so sibling extension files in
/// the same module can instantiate and mutate it.
struct CloudKitMonthData {
  var start: Date
  var end: Date
  let instrument: Instrument
  var income: InstrumentAmount
  var expense: InstrumentAmount
  var profit: InstrumentAmount
  var earmarkedIncome: InstrumentAmount
  var earmarkedExpense: InstrumentAmount
  var earmarkedProfit: InstrumentAmount

  init(start: Date, end: Date, instrument: Instrument) {
    self.start = start
    self.end = end
    self.instrument = instrument
    self.income = .zero(instrument: instrument)
    self.expense = .zero(instrument: instrument)
    self.profit = .zero(instrument: instrument)
    self.earmarkedIncome = .zero(instrument: instrument)
    self.earmarkedExpense = .zero(instrument: instrument)
    self.earmarkedProfit = .zero(instrument: instrument)
  }
}

final class CloudKitAnalysisRepository: AnalysisRepository, @unchecked Sendable {
  // internal (was private) so sibling extension files can read the container
  // when they need a MainActor fetch on behalf of the class.
  let modelContainer: ModelContainer
  // internal (was private) so sibling extension files can read the profile
  // instrument without taking it as a parameter on every helper.
  let instrument: Instrument
  // internal (was private) so sibling extension files can access the shared
  // conversion service.
  let conversionService: any InstrumentConversionService

  init(
    modelContainer: ModelContainer,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) {
    self.modelContainer = modelContainer
    self.instrument = instrument
    self.conversionService = conversionService
  }

  @MainActor private var context: ModelContext {
    modelContainer.mainContext
  }

  /// Bundle of stored conversion context for the static compute path.
  var analysisContext: CloudKitAnalysisContext {
    CloudKitAnalysisContext(instrument: instrument, conversionService: conversionService)
  }

  // MARK: - Batch Loading

  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData {
    let shared = try await fetchSharedData()
    let context = analysisContext

    async let balances = Self.computeDailyBalances(
      request: DailyBalancesRequest(
        nonScheduled: shared.nonScheduled,
        scheduled: shared.scheduled,
        accounts: shared.accounts,
        investmentValues: shared.investmentValues,
        after: historyAfter,
        forecastUntil: forecastUntil
      ),
      context: context
    )
    async let breakdown = Self.computeExpenseBreakdown(
      nonScheduled: shared.nonScheduled,
      monthEnd: monthEnd,
      after: historyAfter,
      context: context
    )
    async let income = Self.computeIncomeAndExpense(
      nonScheduled: shared.nonScheduled,
      accounts: shared.accounts,
      monthEnd: monthEnd,
      after: historyAfter,
      context: context
    )

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income
    )
  }

  // MARK: - AnalysisRepository Conformance

  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    let shared = try await fetchSharedData()
    return try await Self.computeDailyBalances(
      request: DailyBalancesRequest(
        nonScheduled: shared.nonScheduled,
        scheduled: shared.scheduled,
        accounts: shared.accounts,
        investmentValues: shared.investmentValues,
        after: after,
        forecastUntil: forecastUntil
      ),
      context: analysisContext
    )
  }

  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown] {
    let nonScheduled = try await fetchTransactions(filter: .nonScheduledOnly)
    return try await Self.computeExpenseBreakdown(
      nonScheduled: nonScheduled,
      monthEnd: monthEnd,
      after: after,
      context: analysisContext
    )
  }

  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    let nonScheduled = try await fetchTransactions(filter: .nonScheduledOnly)
    let accounts = try await fetchAccounts()
    return try await Self.computeIncomeAndExpense(
      nonScheduled: nonScheduled,
      accounts: accounts,
      monthEnd: monthEnd,
      after: after,
      context: analysisContext
    )
  }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> [UUID: InstrumentAmount] {
    let query = CategoryBalancesQuery(
      dateRange: dateRange,
      transactionType: transactionType,
      filters: filters,
      targetInstrument: targetInstrument,
      conversionService: conversionService
    )
    let allTransactions = try await fetchTransactions(filter: .all)
    var balances: [UUID: InstrumentAmount] = [:]

    for transaction in allTransactions {
      guard query.shouldInclude(transaction) else { continue }
      try await query.accumulate(transaction: transaction, into: &balances)
    }
    return balances
  }

  /// Parameter bundle for `fetchCategoryBalances`. Encapsulates the filtering
  /// predicate and per-leg accumulation so both helpers stay at a single
  /// parameter each and satisfy the `function_parameter_count` threshold.
  struct CategoryBalancesQuery: Sendable {
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
          conversionService: conversionService
        )
        balances[categoryId, default: .zero(instrument: targetInstrument)] += amount
      }
    }
  }

  // MARK: - Data Fetching Helpers

  /// Bundle of data loaded once on the MainActor and consumed by multiple
  /// off-main computations. Keeping it in one struct matches the pattern of
  /// fetching once and sharing — see `loadAll` for the canonical use.
  struct SharedData: Sendable {
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
      investmentValues: investmentValues
    )
  }

  // internal (was private) so sibling extension files may reuse it; currently
  // only called from within this file but kept `internal` to satisfy
  // strict_fileprivate and allow future reuse.
  func fetchTransactions(filter: ScheduledFilter) async throws -> [Transaction] {
    let txnDescriptor = FetchDescriptor<TransactionRecord>()
    let legDescriptor = FetchDescriptor<TransactionLegRecord>()
    let instrumentDescriptor = FetchDescriptor<InstrumentRecord>()

    return try await MainActor.run {
      let records = try context.fetch(txnDescriptor)
      let allLegRecords = try context.fetch(legDescriptor)
      let allInstrumentRecords = try context.fetch(instrumentDescriptor)

      var instrumentLookup: [String: Instrument] = [:]
      for instrumentRecord in allInstrumentRecords {
        instrumentLookup[instrumentRecord.id] = instrumentRecord.toDomain()
      }

      let legsByTxnId = Dictionary(grouping: allLegRecords, by: \.transactionId)

      var transactions = records.map { record -> Transaction in
        let legRecords = (legsByTxnId[record.id] ?? []).sorted { $0.sortOrder < $1.sortOrder }
        let legs = legRecords.map { legRecord -> TransactionLeg in
          let instrument =
            instrumentLookup[legRecord.instrumentId]
            ?? Instrument.fiat(code: legRecord.instrumentId)
          return legRecord.toDomain(instrument: instrument)
        }
        return record.toDomain(legs: legs)
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

  // internal (was private) so sibling extension files can fetch accounts
  // without re-implementing the SwiftData query.
  func fetchAccounts() async throws -> [Account] {
    let descriptor = FetchDescriptor<AccountRecord>()
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      let instrument = self.instrument
      return records.map {
        Account(
          id: $0.id, name: $0.name, type: AccountType(rawValue: $0.type) ?? .bank,
          instrument: instrument,
          position: $0.position, isHidden: $0.isHidden)
      }
    }
  }

  /// Fetch all investment values for the given accounts from SwiftData,
  /// sorted by date ascending. internal (was private) so sibling extension
  /// files may call it directly.
  func fetchAllInvestmentValues(
    investmentAccountIds: Set<UUID>
  ) async throws -> [InvestmentValueSnapshot] {
    guard !investmentAccountIds.isEmpty else { return [] }
    let descriptor = FetchDescriptor<InvestmentValueRecord>()
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return
        records
        .filter { investmentAccountIds.contains($0.accountId) }
        .map(InvestmentValueSnapshot.init(record:))
        .sorted { $0.date < $1.date }
    }
  }
}
