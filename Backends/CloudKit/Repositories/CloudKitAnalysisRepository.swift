import Foundation
import OSLog
import SwiftData

private let analysisLogger = Logger(
  subsystem: "com.moolah.app", category: "CloudKitAnalysisRepository")

final class CloudKitAnalysisRepository: AnalysisRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let instrument: Instrument
  private let conversionService: any InstrumentConversionService

  init(
    modelContainer: ModelContainer,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) {
    self.modelContainer = modelContainer
    self.instrument = instrument
    self.conversionService = conversionService
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  // MARK: - Batch Loading

  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData {
    // 1. Fetch shared data on MainActor (SwiftData requirement) — done ONCE
    let allTransactions = try await fetchTransactions()
    let accounts = try await fetchAccounts()

    // 2. Split and prepare shared data
    let nonScheduled = allTransactions.filter { !$0.isScheduled }
    let scheduled = allTransactions.filter { $0.isScheduled }
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))
    let investmentValues = try await fetchAllInvestmentValues(
      investmentAccountIds: investmentAccountIds)
    let instrument = self.instrument
    let conversionService = self.conversionService

    // 3. Compute all three analyses concurrently, off the main thread
    async let balances = Self.computeDailyBalances(
      nonScheduled: nonScheduled,
      scheduled: scheduled,
      accounts: accounts,
      investmentValues: investmentValues,
      after: historyAfter,
      forecastUntil: forecastUntil,
      instrument: instrument,
      conversionService: conversionService
    )
    async let breakdown = Self.computeExpenseBreakdown(
      nonScheduled: nonScheduled,
      monthEnd: monthEnd,
      after: historyAfter,
      instrument: instrument,
      conversionService: conversionService
    )
    async let income = Self.computeIncomeAndExpense(
      nonScheduled: nonScheduled,
      accounts: accounts,
      monthEnd: monthEnd,
      after: historyAfter,
      instrument: instrument,
      conversionService: conversionService
    )

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income
    )
  }

  // MARK: - Data Fetching Helpers

  private func fetchTransactions(scheduled: Bool? = nil) async throws -> [Transaction] {
    let txnDescriptor = FetchDescriptor<TransactionRecord>()
    let legDescriptor = FetchDescriptor<TransactionLegRecord>()
    let instrumentDescriptor = FetchDescriptor<InstrumentRecord>()

    return try await MainActor.run {
      let records = try context.fetch(txnDescriptor)
      let allLegRecords = try context.fetch(legDescriptor)
      let allInstrumentRecords = try context.fetch(instrumentDescriptor)

      // Build instrument lookup
      var instrumentLookup: [String: Instrument] = [:]
      for ir in allInstrumentRecords {
        instrumentLookup[ir.id] = ir.toDomain()
      }

      // Group legs by transactionId
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

      if let scheduled {
        transactions = transactions.filter { $0.isScheduled == scheduled }
      }
      return transactions
    }
  }

  private func fetchAccounts() async throws -> [Account] {
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

  // MARK: - Daily Balances

  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    // Fetch shared data on MainActor (SwiftData requirement) and split scheduled
    // vs non-scheduled, then delegate to the off-main static computation path.
    let allTransactions = try await fetchTransactions()
    let accounts = try await fetchAccounts()
    let nonScheduled = allTransactions.filter { !$0.isScheduled }
    let scheduled = allTransactions.filter { $0.isScheduled }
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))
    let investmentValues = try await fetchAllInvestmentValues(
      investmentAccountIds: investmentAccountIds)
    let instrument = self.instrument
    let conversionService = self.conversionService

    return try await Self.computeDailyBalances(
      nonScheduled: nonScheduled,
      scheduled: scheduled,
      accounts: accounts,
      investmentValues: investmentValues,
      after: after,
      forecastUntil: forecastUntil,
      instrument: instrument,
      conversionService: conversionService
    )
  }

  /// Fetch all investment values for the given accounts from SwiftData, sorted by date ascending.
  private func fetchAllInvestmentValues(
    investmentAccountIds: Set<UUID>
  ) async throws -> [(accountId: UUID, date: Date, value: InstrumentAmount)] {
    guard !investmentAccountIds.isEmpty else { return [] }
    let descriptor = FetchDescriptor<InvestmentValueRecord>()
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return
        records
        .filter { investmentAccountIds.contains($0.accountId) }
        .map { (accountId: $0.accountId, date: $0.date, value: $0.toDomain().value) }
        .sorted { $0.date < $1.date }
    }
  }

  // MARK: - Expense Breakdown

  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown] {
    // 1. Fetch all non-scheduled transactions
    let allTransactions = try await fetchTransactions(scheduled: false)

    // 2. Filter and group by (categoryId, financialMonth) using legs
    var breakdown: [String: [UUID?: InstrumentAmount]] = [:]
    var lastFinancialDate: Date?
    var lastFinancialMonth: String = ""

    for txn in allTransactions {
      if let after, txn.date < after { continue }

      let month: String
      if let last = lastFinancialDate, txn.date.isSameDay(as: last) {
        month = lastFinancialMonth
      } else {
        month = Self.financialMonth(for: txn.date, monthEnd: monthEnd)
        lastFinancialMonth = month
        lastFinancialDate = txn.date
      }

      // Server: WHERE type = 'expense' AND category_id IS NOT NULL
      for leg in txn.legs where leg.type == .expense && leg.categoryId != nil {
        let categoryId = leg.categoryId
        if breakdown[month] == nil {
          breakdown[month] = [:]
        }
        let amount = try await Self.convertedAmount(
          leg, to: instrument, on: txn.date, conversionService: conversionService)
        let current = breakdown[month]![categoryId] ?? .zero(instrument: instrument)
        breakdown[month]![categoryId] = current + amount
      }
    }

    // 3. Flatten to ExpenseBreakdown array
    var results: [ExpenseBreakdown] = []
    for (month, categories) in breakdown {
      for (categoryId, total) in categories {
        results.append(
          ExpenseBreakdown(
            categoryId: categoryId,
            month: month,
            totalExpenses: total
          ))
      }
    }

    return results.sorted { $0.month > $1.month }
  }

  // MARK: - Income and Expense

  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    // 1. Fetch all non-scheduled transactions
    let allTransactions = try await fetchTransactions(scheduled: false)

    // 2. Get investment account IDs
    let accounts = try await fetchAccounts()
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    // 3. Group by financial month using legs
    var monthlyData: [String: CloudKitMonthData] = [:]
    var lastFinancialDate2: Date?
    var lastFinancialMonth2: String = ""

    for txn in allTransactions {
      if let after, txn.date < after { continue }
      guard !txn.legs.isEmpty else { continue }

      let month: String
      if let last = lastFinancialDate2, txn.date.isSameDay(as: last) {
        month = lastFinancialMonth2
      } else {
        month = Self.financialMonth(for: txn.date, monthEnd: monthEnd)
        lastFinancialMonth2 = month
        lastFinancialDate2 = txn.date
      }

      if monthlyData[month] == nil {
        monthlyData[month] = CloudKitMonthData(
          start: txn.date, end: txn.date, instrument: instrument)
      }

      if txn.date < monthlyData[month]!.start {
        monthlyData[month]!.start = txn.date
      }
      if txn.date > monthlyData[month]!.end {
        monthlyData[month]!.end = txn.date
      }

      for leg in txn.legs {
        let isEarmarked = leg.earmarkId != nil
        let isInvestmentAccount = leg.accountId.map(investmentAccountIds.contains) ?? false
        let amount = try await Self.convertedAmount(
          leg, to: instrument, on: txn.date, conversionService: conversionService)

        switch leg.type {
        case .income:
          // Server: SUM(IF(type='income' AND account_id IS NOT NULL, amount, 0))
          // Include in main total only when leg has an account (matching server).
          // Earmark-only income (nil accountId) goes to earmarkedIncome only.
          if leg.accountId != nil {
            monthlyData[month]!.income += amount
          }
          if isEarmarked {
            monthlyData[month]!.earmarkedIncome += amount
          }

        case .openingBalance:
          // Server excludes openingBalance from income/expense reports.
          break

        case .expense:
          // Server: SUM(IF(type='expense' AND account_id IS NOT NULL, amount, 0))
          // Expenses are negative, refunds are positive — pass through as-is
          // to match the server convention.
          if leg.accountId != nil {
            monthlyData[month]!.expense += amount
          }
          if isEarmarked {
            monthlyData[month]!.earmarkedExpense += amount
          }

        case .transfer:
          if isInvestmentAccount {
            if amount.quantity > 0 {
              monthlyData[month]!.earmarkedIncome += amount
            } else if amount.quantity < 0 {
              monthlyData[month]!.earmarkedExpense += InstrumentAmount(
                quantity: -amount.quantity, instrument: instrument)
            }
          }
        }

        // Server: profit = SUM(IF(account_id IS NOT NULL AND type IN ('income','expense'), amount, 0))
        // Server: earmarkedProfit = SUM(earmarked income/expense amounts) + SUM(transfer adjustments)
        // Accumulate profit directly rather than deriving from income/expense,
        // because transfer contributions to earmarkedExpense use a different sign convention.
        if leg.type == .income || leg.type == .expense {
          if leg.accountId != nil {
            monthlyData[month]!.profit += amount
          }
          if isEarmarked {
            monthlyData[month]!.earmarkedProfit += amount
          }
        } else if leg.type == .transfer, isInvestmentAccount {
          // Investment transfer profit = raw contribution amount.
          // Deposits (positive) add to earmarked profit; withdrawals (negative) subtract.
          monthlyData[month]!.earmarkedProfit += amount
        }
      }
    }

    // 4. Convert to MonthlyIncomeExpense array
    return monthlyData.map { month, data in
      MonthlyIncomeExpense(
        month: month,
        start: data.start,
        end: data.end,
        income: data.income,
        expense: data.expense,
        profit: data.profit,
        earmarkedIncome: data.earmarkedIncome,
        earmarkedExpense: data.earmarkedExpense,
        earmarkedProfit: data.earmarkedProfit
      )
    }.sorted { $0.month > $1.month }
  }

  // MARK: - Category Balances

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> [UUID: InstrumentAmount] {
    // 1. Fetch all transactions
    let allTransactions = try await fetchTransactions()

    // 2. Apply filters and aggregate by category using legs
    var balances: [UUID: InstrumentAmount] = [:]

    for tx in allTransactions {
      guard dateRange.contains(tx.date) else { continue }
      guard tx.recurPeriod == nil else { continue }

      if let accountId = filters?.accountId {
        guard tx.accountIds.contains(accountId) else { continue }
      }
      if let payee = filters?.payee, tx.payee != payee {
        continue
      }

      for leg in tx.legs {
        guard leg.type == transactionType else { continue }
        guard let categoryId = leg.categoryId else { continue }

        if let earmarkId = filters?.earmarkId, leg.earmarkId != earmarkId {
          continue
        }
        if let categoryIds = filters?.categoryIds, !categoryIds.contains(categoryId) {
          continue
        }

        let amount = try await Self.convertedAmount(
          leg, to: targetInstrument, on: tx.date, conversionService: conversionService)
        balances[categoryId, default: .zero(instrument: targetInstrument)] += amount
      }
    }

    return balances
  }

  // MARK: - Currency Conversion Helper

  /// Convert a transaction leg's amount to the profile instrument, using the conversion service
  /// when the leg's instrument differs from the target.
  private static func convertedAmount(
    _ leg: TransactionLeg,
    to instrument: Instrument,
    on date: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    if leg.instrument.id == instrument.id {
      return leg.amount
    }
    let converted = try await conversionService.convert(
      leg.quantity, from: leg.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }

  /// Return a copy of the transaction with every leg's quantity/instrument rewritten
  /// into the profile instrument. Used before feeding scheduled-transaction instances
  /// into the forecast accumulator so every leg already shares the profile instrument
  /// when `PositionBook.dailyBalance` is queried (skipping the multi-instrument
  /// conversion path on every forecast day).
  ///
  /// - Parameter date: date passed to the conversion service. For forecast use, this
  ///   is `Date()` — the current rate — because scheduled transactions have future
  ///   dates and no exchange-rate source has future rates. Same-instrument legs are
  ///   returned untouched.
  private static func convertLegsToProfileInstrument(
    _ txn: Transaction,
    to instrument: Instrument,
    on date: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> Transaction {
    guard txn.legs.contains(where: { $0.instrument.id != instrument.id }) else {
      return txn
    }
    var convertedLegs: [TransactionLeg] = []
    convertedLegs.reserveCapacity(txn.legs.count)
    for leg in txn.legs {
      if leg.instrument.id == instrument.id {
        convertedLegs.append(leg)
        continue
      }
      let convertedQty = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: instrument, on: date)
      convertedLegs.append(
        TransactionLeg(
          accountId: leg.accountId,
          instrument: instrument,
          quantity: convertedQty,
          type: leg.type,
          categoryId: leg.categoryId,
          earmarkId: leg.earmarkId
        ))
    }
    var result = txn
    result.legs = convertedLegs
    return result
  }

  // MARK: - Static Computation Methods (for off-main-thread use)

  @concurrent
  private static func computeDailyBalances(
    nonScheduled: [Transaction],
    scheduled: [Transaction],
    accounts: [Account],
    investmentValues: [(accountId: UUID, date: Date, value: InstrumentAmount)],
    after: Date?,
    forecastUntil: Date?,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [DailyBalance] {
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))
    let sorted = nonScheduled.sorted { $0.date < $1.date }

    var book = PositionBook.empty
    var dailyBalances: [Date: DailyBalance] = [:]

    // Pre-`after` priors: walk into the book with asStartingBalance: true so
    // that non-transfer legs on investment accounts seed the transfers-only
    // baseline. This preserves the legacy single-currency semantic:
    // `investments` for each post-`after` day = snapshot at `after` +
    // post-`after` transfers.
    if let after {
      for txn in sorted where txn.date < after {
        book.apply(
          txn, investmentAccountIds: investmentAccountIds, asStartingBalance: true)
      }
    }

    // Post-`after` daily updates: normal accumulation. Only `.transfer` legs on
    // investment accounts contribute to the transfers-only read.
    //
    // Per Rule 11 (`guides/INSTRUMENT_CONVERSION_GUIDE.md`), a single failing
    // conversion on one day's snapshot must not nuke sibling days. Scope the
    // catch to the per-day `dailyBalance` call so an unresolvable rate only
    // drops that one day's entry; remaining days render normally. The failing
    // day's total is unavailable (omitted) rather than rendered with a
    // silently-dropped input.
    for txn in sorted where after.map({ txn.date >= $0 }) ?? true {
      book.apply(txn, investmentAccountIds: investmentAccountIds)
      let dayKey = Calendar.current.startOfDay(for: txn.date)
      do {
        dailyBalances[dayKey] = try await book.dailyBalance(
          on: txn.date,
          investmentAccountIds: investmentAccountIds,
          profileInstrument: instrument,
          rule: .investmentTransfersOnly,
          conversionService: conversionService,
          isForecast: false
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        analysisLogger.warning(
          """
          Skipping daily balance for \(dayKey, privacy: .public) — conversion \
          failed: \(error.localizedDescription, privacy: .public). \
          Sibling days continue to render.
          """
        )
      }
    }

    // Apply investment values (overrides net worth with market values where available)
    try await applyInvestmentValues(
      investmentValues, to: &dailyBalances,
      instrument: instrument, conversionService: conversionService)

    // Compute bestFit
    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    CloudKitAnalysisRepository.applyBestFit(to: &actualBalances, instrument: instrument)

    // Generate forecasted balances if requested. The `book` above already
    // holds the full position at the end of the in-window range, so we can
    // pass it straight to `generateForecast` as the starting state.
    var forecastBalances: [DailyBalance] = []
    if let forecastUntil {
      let lastDate =
        sorted.last(where: { txn in after.map({ txn.date >= $0 }) ?? true })?.date
        ?? Date()
      forecastBalances = try await generateForecast(
        scheduled: scheduled,
        startingBook: book,
        startDate: lastDate,
        endDate: forecastUntil,
        investmentAccountIds: investmentAccountIds,
        profileInstrument: instrument,
        conversionService: conversionService
      )
    }

    return actualBalances + forecastBalances
  }

  @concurrent
  private static func computeExpenseBreakdown(
    nonScheduled: [Transaction],
    monthEnd: Int,
    after: Date?,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [ExpenseBreakdown] {
    var breakdown: [String: [UUID?: InstrumentAmount]] = [:]
    var lastFinDate: Date?
    var lastFinMonth: String = ""

    for txn in nonScheduled {
      if let after, txn.date < after { continue }

      let month: String
      if let last = lastFinDate, txn.date.isSameDay(as: last) {
        month = lastFinMonth
      } else {
        month = financialMonth(for: txn.date, monthEnd: monthEnd)
        lastFinMonth = month
        lastFinDate = txn.date
      }

      for leg in txn.legs where leg.type == .expense && leg.categoryId != nil {
        let categoryId = leg.categoryId
        if breakdown[month] == nil {
          breakdown[month] = [:]
        }
        let amount = try await convertedAmount(
          leg, to: instrument, on: txn.date, conversionService: conversionService)
        let current = breakdown[month]![categoryId] ?? .zero(instrument: instrument)
        breakdown[month]![categoryId] = current + amount
      }
    }
    var results: [ExpenseBreakdown] = []
    for (month, categories) in breakdown {
      for (categoryId, total) in categories {
        results.append(
          ExpenseBreakdown(
            categoryId: categoryId,
            month: month,
            totalExpenses: total
          ))
      }
    }

    return results.sorted { $0.month > $1.month }
  }

  @concurrent
  private static func computeIncomeAndExpense(
    nonScheduled: [Transaction],
    accounts: [Account],
    monthEnd: Int,
    after: Date?,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [MonthlyIncomeExpense] {
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    var monthlyData: [String: CloudKitMonthData] = [:]
    var lastFinDate2: Date?
    var lastFinMonth2: String = ""

    for txn in nonScheduled {
      if let after, txn.date < after { continue }
      guard !txn.legs.isEmpty else { continue }

      let month: String
      if let last = lastFinDate2, txn.date.isSameDay(as: last) {
        month = lastFinMonth2
      } else {
        month = financialMonth(for: txn.date, monthEnd: monthEnd)
        lastFinMonth2 = month
        lastFinDate2 = txn.date
      }

      if monthlyData[month] == nil {
        monthlyData[month] = CloudKitMonthData(
          start: txn.date, end: txn.date, instrument: instrument)
      }

      if txn.date < monthlyData[month]!.start {
        monthlyData[month]!.start = txn.date
      }
      if txn.date > monthlyData[month]!.end {
        monthlyData[month]!.end = txn.date
      }

      for leg in txn.legs {
        let isEarmarked = leg.earmarkId != nil
        let isInvestmentAccount = leg.accountId.map(investmentAccountIds.contains) ?? false
        let amount = try await convertedAmount(
          leg, to: instrument, on: txn.date, conversionService: conversionService)

        switch leg.type {
        case .income:
          if leg.accountId != nil {
            monthlyData[month]!.income += amount
          }
          if isEarmarked {
            monthlyData[month]!.earmarkedIncome += amount
          }

        case .openingBalance:
          break

        case .expense:
          if leg.accountId != nil {
            monthlyData[month]!.expense += amount
          }
          if isEarmarked {
            monthlyData[month]!.earmarkedExpense += amount
          }

        case .transfer:
          if isInvestmentAccount {
            if amount.quantity > 0 {
              monthlyData[month]!.earmarkedIncome += amount
            } else if amount.quantity < 0 {
              monthlyData[month]!.earmarkedExpense += InstrumentAmount(
                quantity: -amount.quantity, instrument: instrument)
            }
          }
        }

        if leg.type == .income || leg.type == .expense {
          if leg.accountId != nil {
            monthlyData[month]!.profit += amount
          }
          if isEarmarked {
            monthlyData[month]!.earmarkedProfit += amount
          }
        } else if leg.type == .transfer, isInvestmentAccount {
          monthlyData[month]!.earmarkedProfit += amount
        }
      }
    }

    return monthlyData.map { month, data in
      MonthlyIncomeExpense(
        month: month,
        start: data.start,
        end: data.end,
        income: data.income,
        expense: data.expense,
        profit: data.profit,
        earmarkedIncome: data.earmarkedIncome,
        earmarkedExpense: data.earmarkedExpense,
        earmarkedProfit: data.earmarkedProfit
      )
    }.sorted { $0.month > $1.month }
  }

  // MARK: - Static Helper Methods

  private static func applyInvestmentValues(
    _ investmentValues: [(accountId: UUID, date: Date, value: InstrumentAmount)],
    to dailyBalances: inout [Date: DailyBalance],
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws {
    guard !investmentValues.isEmpty, !dailyBalances.isEmpty else { return }

    var latestByAccount: [UUID: InstrumentAmount] = [:]
    var valueIndex = 0

    for date in dailyBalances.keys.sorted() {
      while valueIndex < investmentValues.count {
        let entry = investmentValues[valueIndex]
        let entryDay = Calendar.current.startOfDay(for: entry.date)
        if entryDay <= date {
          latestByAccount[entry.accountId] = entry.value
          valueIndex += 1
        } else {
          break
        }
      }

      if !latestByAccount.isEmpty {
        // Sum values, converting to profile instrument where needed.
        //
        // Rule 11 scoping: if one foreign-currency investment value can't be
        // converted on this day, mark this day's `investmentValue` unavailable
        // (leave it at its prior state — typically `nil`) rather than
        // aborting the whole balance history. Sibling days keep rendering.
        var total: Decimal = 0
        var didFail = false
        for value in latestByAccount.values {
          if value.instrument.id == instrument.id {
            total += value.quantity
          } else {
            do {
              total += try await conversionService.convert(
                value.quantity, from: value.instrument, to: instrument, on: date)
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              analysisLogger.warning(
                """
                Skipping investmentValue for \(date, privacy: .public) — \
                conversion of \(value.instrument.id, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public).
                """
              )
              didFail = true
              break
            }
          }
        }
        if didFail { continue }
        let totalValue = InstrumentAmount(quantity: total, instrument: instrument)
        let balance = dailyBalances[date]!
        dailyBalances[date] = DailyBalance(
          date: balance.date,
          balance: balance.balance,
          earmarked: balance.earmarked,
          availableFunds: balance.availableFunds,
          investments: balance.investments,
          investmentValue: totalValue,
          netWorth: balance.balance + totalValue,
          bestFit: balance.bestFit,
          isForecast: balance.isForecast
        )
      }
    }
  }

  /// Apply linear regression best-fit line to daily balances.
  /// Uses availableFunds as the y-axis value and day offset as x-axis.
  static func applyBestFit(to balances: inout [DailyBalance], instrument: Instrument) {
    guard balances.count >= 2 else { return }

    let referenceDate = balances[0].date
    let calendar = Calendar.current

    var sumX: Double = 0
    var sumY: Double = 0
    var sumXY: Double = 0
    var sumXX: Double = 0
    let n = Double(balances.count)

    var xValues: [Double] = []
    for balance in balances {
      let x = Double(
        calendar.dateComponents([.day], from: referenceDate, to: balance.date).day ?? 0)
      let y = Double(truncating: balance.availableFunds.quantity as NSDecimalNumber)
      xValues.append(x)
      sumX += x
      sumY += y
      sumXY += x * y
      sumXX += x * x
    }

    let denominator = n * sumXX - sumX * sumX
    guard abs(denominator) > 0.001 else { return }

    let m = (n * sumXY - sumX * sumY) / denominator
    let b = (sumY - m * sumX) / n

    for i in balances.indices {
      let predicted = Decimal(m * xValues[i] + b)
      balances[i] = DailyBalance(
        date: balances[i].date,
        balance: balances[i].balance,
        earmarked: balances[i].earmarked,
        availableFunds: balances[i].availableFunds,
        investments: balances[i].investments,
        investmentValue: balances[i].investmentValue,
        netWorth: balances[i].netWorth,
        bestFit: InstrumentAmount(quantity: predicted, instrument: instrument),
        isForecast: balances[i].isForecast
      )
    }
  }

  private static func generateForecast(
    scheduled: [Transaction],
    startingBook: PositionBook,
    startDate: Date,
    endDate: Date,
    investmentAccountIds: Set<UUID>,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [DailyBalance] {
    // Extrapolate instances up to endDate
    var instances: [Transaction] = []
    for scheduledTxn in scheduled {
      instances.append(contentsOf: extrapolateScheduledTransaction(scheduledTxn, until: endDate))
    }

    // Sort by date and apply to running balances
    instances.sort { $0.date < $1.date }
    var book = startingBook
    let instrument = profileInstrument

    // Scheduled transactions live in the future; exchange-rate sources can't return
    // future rates. Use today's rate as the best available estimate for forecast
    // conversion. Captured once so every instance uses the same snapshot.
    let conversionDate = Date()

    // Pre-convert all instances concurrently — each conversion is independent.
    // The accumulator that follows is inherently sequential (each iteration
    // depends on the previous running totals), so we can't parallelise it.
    // See guides/CONCURRENCY_GUIDE.md: dynamic count → TaskGroup.
    //
    // After pre-conversion, every leg's instrument == profileInstrument, so
    // `book.dailyBalance` will hit the single-instrument fast path on every
    // call below — no extra conversion cost from the multi-instrument
    // accumulator.
    let converted: [Transaction]
    if instances.isEmpty {
      converted = []
    } else {
      converted = try await withThrowingTaskGroup(
        of: (Int, Transaction).self
      ) { group in
        for (i, instance) in instances.enumerated() {
          group.addTask {
            let txn = try await convertLegsToProfileInstrument(
              instance, to: instrument, on: conversionDate,
              conversionService: conversionService)
            return (i, txn)
          }
        }
        var out = Array(repeating: instances[0], count: instances.count)
        for try await (i, txn) in group { out[i] = txn }
        return out
      }
    }

    var forecastBalances: [Date: DailyBalance] = [:]
    for instance in converted {
      book.apply(instance, investmentAccountIds: investmentAccountIds)

      let dayKey = Calendar.current.startOfDay(for: instance.date)
      // See Rule 11 scoping note in `computeDailyBalances`: a single day's
      // conversion failure must not drop sibling forecast days. Legs have
      // already been pre-converted to the profile instrument above, so in
      // practice the only way this throws is an upstream bug — still, scope
      // the catch so the forecast series degrades gracefully instead of
      // truncating.
      do {
        forecastBalances[dayKey] = try await book.dailyBalance(
          on: instance.date,
          investmentAccountIds: investmentAccountIds,
          profileInstrument: instrument,
          rule: .investmentTransfersOnly,
          conversionService: conversionService,
          isForecast: true
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        analysisLogger.warning(
          """
          Skipping forecast balance for \(dayKey, privacy: .public) — \
          conversion failed: \(error.localizedDescription, privacy: .public). \
          Sibling forecast days continue to render.
          """
        )
      }
    }

    return forecastBalances.values.sorted { $0.date < $1.date }
  }

  private static func extrapolateScheduledTransaction(
    _ scheduled: Transaction,
    until endDate: Date
  ) -> [Transaction] {
    guard let period = scheduled.recurPeriod, period != .once else {
      return scheduled.date <= endDate ? [scheduled] : []
    }

    let every = scheduled.recurEvery ?? 1
    var instances: [Transaction] = []
    var currentDate = scheduled.date

    while currentDate <= endDate {
      var instance = scheduled
      instance.date = currentDate
      instance.recurPeriod = nil
      instance.recurEvery = nil
      instances.append(instance)

      guard let nextDate = nextDueDate(from: currentDate, period: period, every: every) else {
        break
      }
      currentDate = nextDate
    }

    return instances
  }

  private static func nextDueDate(from date: Date, period: RecurPeriod, every: Int) -> Date? {
    let calendar = Calendar.current
    var components = DateComponents()

    switch period {
    case .day:
      components.day = every
    case .week:
      components.weekOfYear = every
    case .month:
      components.month = every
    case .year:
      components.year = every
    case .once:
      return nil
    }

    return calendar.date(byAdding: components, to: date)
  }

  private static func financialMonth(for date: Date, monthEnd: Int) -> String {
    let calendar = Calendar.current
    let dayOfMonth = calendar.component(.day, from: date)
    let adjustedDate =
      dayOfMonth > monthEnd
      ? calendar.date(byAdding: .month, value: 1, to: date)!
      : date

    let year = calendar.component(.year, from: adjustedDate)
    let month = calendar.component(.month, from: adjustedDate)
    return String(format: "%04d%02d", year, month)
  }
}

// Helper struct for building monthly data (prefixed to avoid collision with InMemory version)
private struct CloudKitMonthData {
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
