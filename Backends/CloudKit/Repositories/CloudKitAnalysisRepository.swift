import Foundation
import SwiftData

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
    // 1. Fetch all non-scheduled transactions
    let allTransactions = try await fetchTransactions(scheduled: false)

    // 2. Filter by date range and sort chronologically (sorted once, reused below)
    let transactions = allTransactions.filter { txn in
      guard let after else { return true }
      return txn.date >= after
    }.sorted(by: { $0.date < $1.date })

    // 3. Get accounts to classify as current vs investment
    let accounts = try await fetchAccounts()
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    // 4. Compute daily balances
    var dailyBalances: [Date: DailyBalance] = [:]
    var currentBalance: InstrumentAmount = .zero(instrument: instrument)
    var currentInvestments: InstrumentAmount = .zero(instrument: instrument)
    var perEarmarkAmounts: [UUID: InstrumentAmount] = [:]

    // If 'after' is provided, compute starting balances up to that date
    if let after {
      let priorTransactions = allTransactions.filter { $0.date < after }

      for txn in priorTransactions.sorted(by: { $0.date < $1.date }) {
        Self.applyTransaction(
          txn,
          to: &currentBalance,
          investments: &currentInvestments,
          perEarmarkAmounts: &perEarmarkAmounts,
          instrument: instrument,
          investmentAccountIds: investmentAccountIds,
          investmentTransfersOnly: false
        )
      }
    }

    // Apply each transaction to running balances (transactions already sorted above)
    var lastDayDate: Date?
    var lastDayKey: Date = .distantPast

    for txn in transactions {
      Self.applyTransaction(
        txn,
        to: &currentBalance,
        investments: &currentInvestments,
        perEarmarkAmounts: &perEarmarkAmounts,
        instrument: instrument,
        investmentAccountIds: investmentAccountIds,
        investmentTransfersOnly: true
      )

      let dayKey: Date
      if let last = lastDayDate, txn.date.isSameDay(as: last) {
        dayKey = lastDayKey
      } else {
        dayKey = Calendar.current.startOfDay(for: txn.date)
        lastDayKey = dayKey
        lastDayDate = txn.date
      }
      let currentEarmarks = Self.clampedEarmarkTotal(perEarmarkAmounts, instrument: instrument)
      dailyBalances[dayKey] = DailyBalance(
        date: dayKey,
        balance: currentBalance,
        earmarked: currentEarmarks,
        availableFunds: currentBalance - currentEarmarks,
        investments: currentInvestments,
        investmentValue: nil,
        netWorth: currentBalance + currentInvestments,
        bestFit: nil,
        isForecast: false
      )
    }

    // 5. Convert multi-instrument positions to profile currency if needed
    try await Self.applyMultiInstrumentConversion(
      to: &dailyBalances,
      allTransactions: allTransactions,
      investmentAccountIds: investmentAccountIds,
      instrument: instrument,
      conversionService: conversionService
    )

    // 6. Apply investment values (overrides net worth with market values where available)
    let investmentValues = try await fetchAllInvestmentValues(
      investmentAccountIds: investmentAccountIds)
    try await Self.applyInvestmentValues(
      investmentValues, to: &dailyBalances, instrument: instrument,
      conversionService: conversionService)

    // 6. Compute bestFit (linear regression on availableFunds)
    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    CloudKitAnalysisRepository.applyBestFit(to: &actualBalances, instrument: instrument)

    // 7. Generate forecasted balances if requested
    var scheduledBalances: [DailyBalance] = []
    if let forecastUntil {
      let scheduledTransactions = try await fetchTransactions(scheduled: true)
      // transactions is sorted chronologically, so .last is the most recent date
      let lastDate = transactions.last?.date ?? Date()
      scheduledBalances = try await Self.generateForecast(
        scheduled: scheduledTransactions,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingPerEarmarkAmounts: perEarmarkAmounts,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds,
        conversionService: conversionService
      )
    }

    // 8. Combine and return
    return actualBalances + scheduledBalances
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
    filters: TransactionFilter?
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
          leg, to: instrument, on: tx.date, conversionService: conversionService)
        balances[categoryId, default: .zero(instrument: instrument)] += amount
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
  /// into the forecast accumulator so the synchronous `applyTransaction` can assume
  /// all legs share the profile instrument.
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

    // Filter by date range and sort chronologically (sorted once, reused below)
    let transactions: [Transaction]
    if let after {
      transactions = nonScheduled.filter { $0.date >= after }.sorted(by: { $0.date < $1.date })
    } else {
      transactions = nonScheduled.sorted(by: { $0.date < $1.date })
    }

    // Compute daily balances
    var dailyBalances: [Date: DailyBalance] = [:]
    var currentBalance: InstrumentAmount = .zero(instrument: instrument)
    var currentInvestments: InstrumentAmount = .zero(instrument: instrument)
    var perEarmarkAmounts: [UUID: InstrumentAmount] = [:]

    // If 'after' is provided, compute starting balances up to that date.
    // Starting balance includes ALL leg types on investment accounts
    // (matching server's selectBalance for hasInvestmentAccount).
    if let after {
      let priorTransactions = nonScheduled.filter { $0.date < after }
      for txn in priorTransactions.sorted(by: { $0.date < $1.date }) {
        applyTransaction(
          txn,
          to: &currentBalance,
          investments: &currentInvestments,
          perEarmarkAmounts: &perEarmarkAmounts,
          instrument: instrument,
          investmentAccountIds: investmentAccountIds,
          investmentTransfersOnly: false
        )
      }
    }

    // Apply each transaction to running balances (transactions already sorted above).
    // Only TRANSFER legs change the investment running total for daily deltas
    // (matching server's dailyProfitAndLoss which only counts transfers
    // between investment and non-investment accounts).
    var lastComputeDayDate: Date?
    var lastComputeDayKey: Date = .distantPast

    for txn in transactions {
      applyTransaction(
        txn,
        to: &currentBalance,
        investments: &currentInvestments,
        perEarmarkAmounts: &perEarmarkAmounts,
        instrument: instrument,
        investmentAccountIds: investmentAccountIds,
        investmentTransfersOnly: true
      )

      let dayKey: Date
      if let last = lastComputeDayDate, txn.date.isSameDay(as: last) {
        dayKey = lastComputeDayKey
      } else {
        dayKey = Calendar.current.startOfDay(for: txn.date)
        lastComputeDayKey = dayKey
        lastComputeDayDate = txn.date
      }
      let currentEarmarks = clampedEarmarkTotal(perEarmarkAmounts, instrument: instrument)
      dailyBalances[dayKey] = DailyBalance(
        date: dayKey,
        balance: currentBalance,
        earmarked: currentEarmarks,
        availableFunds: currentBalance - currentEarmarks,
        investments: currentInvestments,
        investmentValue: nil,
        netWorth: currentBalance + currentInvestments,
        bestFit: nil,
        isForecast: false
      )
    }

    // Convert multi-instrument positions to profile currency if needed
    try await applyMultiInstrumentConversion(
      to: &dailyBalances,
      allTransactions: nonScheduled,
      investmentAccountIds: investmentAccountIds,
      instrument: instrument,
      conversionService: conversionService
    )

    // Apply investment values (overrides net worth with market values where available)
    try await applyInvestmentValues(
      investmentValues, to: &dailyBalances, instrument: instrument,
      conversionService: conversionService)

    // Compute bestFit
    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    CloudKitAnalysisRepository.applyBestFit(to: &actualBalances, instrument: instrument)

    // Generate forecasted balances if requested
    var forecastBalances: [DailyBalance] = []
    if let forecastUntil {
      // transactions is sorted chronologically, so .last is the most recent date
      let lastDate = transactions.last?.date ?? Date()
      forecastBalances = try await generateForecast(
        scheduled: scheduled,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingPerEarmarkAmounts: perEarmarkAmounts,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds,
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

  // MARK: - Multi-Instrument Net Worth

  /// Recomputes daily balances using currency conversion for multi-instrument positions.
  /// Accumulates positions per instrument, converts each to profile currency per day,
  /// then splits into balance (bank accounts) and investments (investment accounts).
  /// Preserves the invariant: netWorth == balance + investmentValue (or balance + investments).
  private static func applyMultiInstrumentConversion(
    to dailyBalances: inout [Date: DailyBalance],
    allTransactions: [Transaction],
    investmentAccountIds: Set<UUID>,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws {
    guard !dailyBalances.isEmpty else { return }

    // Check if any legs use a non-profile instrument; skip if single-instrument
    let hasMultiInstrument = allTransactions.contains { txn in
      txn.legs.contains { $0.instrument.id != instrument.id }
    }
    guard hasMultiInstrument else { return }

    // Sort transactions chronologically
    let sorted = allTransactions.sorted { $0.date < $1.date }
    let calendar = Calendar(identifier: .gregorian)

    // Track positions by instrument, split by bank vs investment
    var bankPositions: [String: (quantity: Decimal, instrument: Instrument)] = [:]
    var investmentPositions: [String: (quantity: Decimal, instrument: Instrument)] = [:]
    var earmarkPositions: [UUID: [String: (quantity: Decimal, instrument: Instrument)]] = [:]

    for txn in sorted {
      let dayKey = calendar.startOfDay(for: txn.date)

      for leg in txn.legs {
        let isInvestment = leg.accountId.map(investmentAccountIds.contains) ?? false
        let key = leg.instrument.id

        if isInvestment {
          investmentPositions[key, default: (0, leg.instrument)].quantity += leg.quantity
        } else {
          bankPositions[key, default: (0, leg.instrument)].quantity += leg.quantity
        }

        if let earmarkId = leg.earmarkId {
          earmarkPositions[earmarkId, default: [:]][key, default: (0, leg.instrument)].quantity +=
            leg.quantity
        }
      }

      // Only update days that have a balance entry
      guard dailyBalances[dayKey] != nil else { continue }

      // Convert all positions to profile currency
      var bankTotal: Decimal = 0
      for (_, pos) in bankPositions where pos.quantity != 0 {
        if pos.instrument.id == instrument.id {
          bankTotal += pos.quantity
        } else {
          bankTotal += try await conversionService.convert(
            pos.quantity, from: pos.instrument, to: instrument, on: txn.date)
        }
      }

      var investTotal: Decimal = 0
      for (_, pos) in investmentPositions where pos.quantity != 0 {
        if pos.instrument.id == instrument.id {
          investTotal += pos.quantity
        } else {
          investTotal += try await conversionService.convert(
            pos.quantity, from: pos.instrument, to: instrument, on: txn.date)
        }
      }

      var earmarkTotal: Decimal = 0
      for (_, positions) in earmarkPositions {
        var perEarmarkTotal: Decimal = 0
        for (_, pos) in positions where pos.quantity != 0 {
          if pos.instrument.id == instrument.id {
            perEarmarkTotal += pos.quantity
          } else {
            perEarmarkTotal += try await conversionService.convert(
              pos.quantity, from: pos.instrument, to: instrument, on: txn.date)
          }
        }
        earmarkTotal += max(perEarmarkTotal, 0)
      }

      let balance = InstrumentAmount(quantity: bankTotal, instrument: instrument)
      let investments = InstrumentAmount(quantity: investTotal, instrument: instrument)
      let earmarked = InstrumentAmount(quantity: earmarkTotal, instrument: instrument)
      let existing = dailyBalances[dayKey]!

      dailyBalances[dayKey] = DailyBalance(
        date: existing.date,
        balance: balance,
        earmarked: earmarked,
        availableFunds: balance - earmarked,
        investments: investments,
        investmentValue: existing.investmentValue,
        netWorth: balance + (existing.investmentValue ?? investments),
        bestFit: existing.bestFit,
        isForecast: existing.isForecast
      )
    }
  }

  // MARK: - Static Helper Methods

  /// Apply a transaction's legs to running balance totals.
  /// Each leg is processed independently based on its type and account.
  /// Apply a transaction's legs to running balance totals.
  ///
  /// - Parameter investmentTransfersOnly: When true, only `.transfer` legs on investment
  ///   accounts affect the `investments` total (matching server's dailyProfitAndLoss
  ///   which only counts transfers between investment/non-investment accounts).
  ///   When false, all leg types on investment accounts count (matching server's
  ///   selectBalance used for starting balances).
  private static func applyTransaction(
    _ txn: Transaction,
    to balance: inout InstrumentAmount,
    investments: inout InstrumentAmount,
    perEarmarkAmounts: inout [UUID: InstrumentAmount],
    instrument: Instrument,
    investmentAccountIds: Set<UUID>,
    investmentTransfersOnly: Bool = false
  ) {
    let zero = InstrumentAmount.zero(instrument: instrument)
    for leg in txn.legs {
      // Only legs with an accountId affect account balances
      // (matching server's account_id IS NOT NULL requirement).
      // Earmark-only legs (nil accountId) only affect the earmarked total.
      if let accountId = leg.accountId {
        if investmentAccountIds.contains(accountId) {
          if !investmentTransfersOnly || leg.type == .transfer {
            investments += leg.amount
          }
        } else {
          balance += leg.amount
        }
      }
      if let earmarkId = leg.earmarkId {
        perEarmarkAmounts[earmarkId, default: zero] += leg.amount
      }
    }
  }

  /// Computes the earmarked total by clamping each earmark's balance to max(0).
  /// Negative earmarks (e.g., investments) should not reduce the total.
  private static func clampedEarmarkTotal(
    _ perEarmark: [UUID: InstrumentAmount],
    instrument: Instrument
  ) -> InstrumentAmount {
    var total = InstrumentAmount.zero(instrument: instrument)
    let zero = InstrumentAmount.zero(instrument: instrument)
    for (_, amount) in perEarmark {
      total += max(amount, zero)
    }
    return total
  }

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
        // Sum values, converting to profile instrument where needed
        var total: Decimal = 0
        for value in latestByAccount.values {
          if value.instrument.id == instrument.id {
            total += value.quantity
          } else {
            total += try await conversionService.convert(
              value.quantity, from: value.instrument, to: instrument, on: date)
          }
        }
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
    startDate: Date,
    endDate: Date,
    startingBalance: InstrumentAmount,
    startingPerEarmarkAmounts: [UUID: InstrumentAmount],
    startingInvestments: InstrumentAmount,
    investmentAccountIds: Set<UUID>,
    conversionService: any InstrumentConversionService
  ) async throws -> [DailyBalance] {
    // Extrapolate instances up to endDate
    var instances: [Transaction] = []
    for scheduledTxn in scheduled {
      instances.append(contentsOf: extrapolateScheduledTransaction(scheduledTxn, until: endDate))
    }

    // Sort by date and apply to running balances
    instances.sort { $0.date < $1.date }
    var balance = startingBalance
    var perEarmarkAmounts = startingPerEarmarkAmounts
    var investments = startingInvestments
    let instrument = startingBalance.instrument

    // Scheduled transactions live in the future; exchange-rate sources can't return
    // future rates. Use today's rate as the best available estimate for forecast
    // conversion. Captured once so every instance uses the same snapshot.
    let conversionDate = Date()

    // Pre-convert all instances concurrently — each conversion is independent.
    // The accumulator that follows is inherently sequential (each iteration
    // depends on the previous running totals), so we can't parallelise it.
    // See guides/CONCURRENCY_GUIDE.md: dynamic count → TaskGroup.
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
      applyTransaction(
        instance,
        to: &balance,
        investments: &investments,
        perEarmarkAmounts: &perEarmarkAmounts,
        instrument: instrument,
        investmentAccountIds: investmentAccountIds,
        investmentTransfersOnly: true
      )

      let dayKey = Calendar.current.startOfDay(for: instance.date)
      let earmarks = clampedEarmarkTotal(perEarmarkAmounts, instrument: instrument)
      forecastBalances[dayKey] = DailyBalance(
        date: dayKey,
        balance: balance,
        earmarked: earmarks,
        availableFunds: balance - earmarks,
        investments: investments,
        investmentValue: nil,
        netWorth: balance + investments,
        bestFit: nil,
        isForecast: true
      )
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
