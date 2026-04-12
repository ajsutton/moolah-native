import Foundation
import SwiftData

final class CloudKitAnalysisRepository: AnalysisRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let currency: Currency

  init(modelContainer: ModelContainer, currency: Currency) {
    self.modelContainer = modelContainer
    self.currency = currency
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
    let currency = self.currency

    // 3. Compute all three analyses concurrently, off the main thread
    async let balances = Self.computeDailyBalances(
      nonScheduled: nonScheduled,
      scheduled: scheduled,
      accounts: accounts,
      investmentValues: investmentValues,
      after: historyAfter,
      forecastUntil: forecastUntil,
      currency: currency
    )
    async let breakdown = Self.computeExpenseBreakdown(
      nonScheduled: nonScheduled,
      monthEnd: monthEnd,
      after: historyAfter,
      currency: currency
    )
    async let income = Self.computeIncomeAndExpense(
      nonScheduled: nonScheduled,
      accounts: accounts,
      monthEnd: monthEnd,
      after: historyAfter,
      currency: currency
    )

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income
    )
  }

  // MARK: - Data Fetching Helpers

  private func fetchTransactions(scheduled: Bool? = nil) async throws -> [Transaction] {
    let descriptor = FetchDescriptor<TransactionRecord>()
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      var transactions = records.map { $0.toDomain() }
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
      return records.map {
        Account(
          id: $0.id, name: $0.name, type: AccountType(rawValue: $0.type) ?? .bank,
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
    var currentBalance: MonetaryAmount = .zero(currency: currency)
    var currentInvestments: MonetaryAmount = .zero(currency: currency)
    var currentEarmarks: MonetaryAmount = .zero(currency: currency)

    // If 'after' is provided, compute starting balances up to that date
    if let after {
      let priorTransactions = allTransactions.filter { $0.date < after }

      for txn in priorTransactions.sorted(by: { $0.date < $1.date }) {
        Self.applyTransaction(
          txn,
          to: &currentBalance,
          investments: &currentInvestments,
          earmarks: &currentEarmarks,
          investmentAccountIds: investmentAccountIds
        )
      }
    }

    // Apply each transaction to running balances (transactions already sorted above)
    for txn in transactions {
      Self.applyTransaction(
        txn,
        to: &currentBalance,
        investments: &currentInvestments,
        earmarks: &currentEarmarks,
        investmentAccountIds: investmentAccountIds
      )

      let dayKey = Calendar.current.startOfDay(for: txn.date)
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

    // 5. Apply investment values from InvestmentValueRecord
    let investmentValues = try await fetchAllInvestmentValues(
      investmentAccountIds: investmentAccountIds)
    Self.applyInvestmentValues(investmentValues, to: &dailyBalances, currency: currency)

    // 6. Compute bestFit (linear regression on availableFunds)
    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    CloudKitAnalysisRepository.applyBestFit(to: &actualBalances, currency: currency)

    // 7. Generate forecasted balances if requested
    var scheduledBalances: [DailyBalance] = []
    if let forecastUntil {
      let scheduledTransactions = try await fetchTransactions(scheduled: true)
      // transactions is sorted chronologically, so .last is the most recent date
      let lastDate = transactions.last?.date ?? Date()
      scheduledBalances = Self.generateForecast(
        scheduled: scheduledTransactions,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingEarmarks: currentEarmarks,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds
      )
    }

    // 8. Combine and return
    return actualBalances + scheduledBalances
  }

  /// Fetch all investment values for the given accounts from SwiftData, sorted by date ascending.
  private func fetchAllInvestmentValues(
    investmentAccountIds: Set<UUID>
  ) async throws -> [(accountId: UUID, date: Date, value: MonetaryAmount)] {
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
    var transactions = try await fetchTransactions(scheduled: false)
    transactions = transactions.filter { $0.type == .expense }

    // 2. Filter by date range
    if let after {
      transactions = transactions.filter { $0.date >= after }
    }

    // 3. Group by (categoryId, financialMonth)
    var breakdown: [String: [UUID?: MonetaryAmount]] = [:]

    for txn in transactions {
      let month = Self.financialMonth(for: txn.date, monthEnd: monthEnd)
      let categoryId = txn.categoryId

      if breakdown[month] == nil {
        breakdown[month] = [:]
      }
      let current = breakdown[month]![categoryId] ?? .zero(currency: currency)
      breakdown[month]![categoryId] = current + txn.amount
    }

    // 4. Flatten to ExpenseBreakdown array
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
    var transactions = try await fetchTransactions(scheduled: false)

    // 2. Filter by date range
    if let after {
      transactions = transactions.filter { $0.date >= after }
    }

    // 3. Get investment account IDs
    let accounts = try await fetchAccounts()
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    // 4. Group by financial month
    var monthlyData: [String: CloudKitMonthData] = [:]

    for txn in transactions {
      guard txn.accountId != nil else { continue }
      let month = Self.financialMonth(for: txn.date, monthEnd: monthEnd)

      if monthlyData[month] == nil {
        monthlyData[month] = CloudKitMonthData(
          start: txn.date, end: txn.date, currency: currency)
      }

      if txn.date < monthlyData[month]!.start {
        monthlyData[month]!.start = txn.date
      }
      if txn.date > monthlyData[month]!.end {
        monthlyData[month]!.end = txn.date
      }

      let isEarmarked = txn.earmarkId != nil
      let isFromInvestment = txn.accountId.map { investmentAccountIds.contains($0) } ?? false
      let isToInvestment = txn.toAccountId.map { investmentAccountIds.contains($0) } ?? false

      switch txn.type {
      case .income, .openingBalance:
        if isEarmarked {
          monthlyData[month]!.earmarkedIncome += txn.amount
        } else {
          monthlyData[month]!.income += txn.amount
        }

      case .expense:
        let absAmount = MonetaryAmount(
          cents: abs(txn.amount.cents),
          currency: txn.amount.currency
        )
        if isEarmarked {
          monthlyData[month]!.earmarkedExpense += absAmount
        } else {
          monthlyData[month]!.expense += absAmount
        }

      case .transfer:
        // Compute profit contribution matching server: +amount for from_investment,
        // -amount for to_investment. Route positive to earmarkedIncome (pool growth),
        // negative to earmarkedExpense (pool shrinkage). This handles positive-amount
        // transfers (e.g. dividend reinvestments) correctly.
        var profitContribution = 0
        if isFromInvestment && !isToInvestment {
          profitContribution = txn.amount.cents
        } else if !isFromInvestment && isToInvestment {
          profitContribution = -txn.amount.cents
        }
        if profitContribution > 0 {
          monthlyData[month]!.earmarkedIncome += MonetaryAmount(
            cents: profitContribution, currency: txn.amount.currency)
        } else if profitContribution < 0 {
          monthlyData[month]!.earmarkedExpense += MonetaryAmount(
            cents: -profitContribution, currency: txn.amount.currency)
        }
      }
    }

    // 5. Convert to MonthlyIncomeExpense array
    return monthlyData.map { month, data in
      MonthlyIncomeExpense(
        month: month,
        start: data.start,
        end: data.end,
        income: data.income,
        expense: data.expense,
        profit: data.income - data.expense,
        earmarkedIncome: data.earmarkedIncome,
        earmarkedExpense: data.earmarkedExpense,
        earmarkedProfit: data.earmarkedIncome - data.earmarkedExpense
      )
    }.sorted { $0.month > $1.month }
  }

  // MARK: - Category Balances

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?
  ) async throws -> [UUID: MonetaryAmount] {
    // 1. Fetch all transactions
    let allTransactions = try await fetchTransactions()

    // 2. Apply filters
    let filtered = allTransactions.filter { tx in
      guard dateRange.contains(tx.date) else { return false }
      guard tx.type == transactionType else { return false }
      guard tx.categoryId != nil else { return false }
      guard tx.recurPeriod == nil else { return false }

      if let accountId = filters?.accountId, tx.accountId != accountId {
        return false
      }
      if let earmarkId = filters?.earmarkId, tx.earmarkId != earmarkId {
        return false
      }
      if let categoryIds = filters?.categoryIds, !categoryIds.contains(tx.categoryId!) {
        return false
      }
      if let payee = filters?.payee, tx.payee != payee {
        return false
      }

      return true
    }

    // 3. Group by category and sum amounts
    var balances: [UUID: MonetaryAmount] = [:]
    for transaction in filtered {
      let categoryId = transaction.categoryId!
      balances[categoryId, default: .zero(currency: transaction.amount.currency)] +=
        transaction.amount
    }

    return balances
  }

  // MARK: - Static Computation Methods (for off-main-thread use)

  @concurrent
  private static func computeDailyBalances(
    nonScheduled: [Transaction],
    scheduled: [Transaction],
    accounts: [Account],
    investmentValues: [(accountId: UUID, date: Date, value: MonetaryAmount)],
    after: Date?,
    forecastUntil: Date?,
    currency: Currency
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
    var currentBalance: MonetaryAmount = .zero(currency: currency)
    var currentInvestments: MonetaryAmount = .zero(currency: currency)
    var currentEarmarks: MonetaryAmount = .zero(currency: currency)

    // If 'after' is provided, compute starting balances up to that date
    if let after {
      let priorTransactions = nonScheduled.filter { $0.date < after }
      for txn in priorTransactions.sorted(by: { $0.date < $1.date }) {
        applyTransaction(
          txn,
          to: &currentBalance,
          investments: &currentInvestments,
          earmarks: &currentEarmarks,
          investmentAccountIds: investmentAccountIds
        )
      }
    }

    // Apply each transaction to running balances (transactions already sorted above)
    for txn in transactions {
      applyTransaction(
        txn,
        to: &currentBalance,
        investments: &currentInvestments,
        earmarks: &currentEarmarks,
        investmentAccountIds: investmentAccountIds
      )

      let dayKey = Calendar.current.startOfDay(for: txn.date)
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

    // Apply investment values
    applyInvestmentValues(investmentValues, to: &dailyBalances, currency: currency)

    // Compute bestFit
    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    CloudKitAnalysisRepository.applyBestFit(to: &actualBalances, currency: currency)

    // Generate forecasted balances if requested
    var forecastBalances: [DailyBalance] = []
    if let forecastUntil {
      // transactions is sorted chronologically, so .last is the most recent date
      let lastDate = transactions.last?.date ?? Date()
      forecastBalances = generateForecast(
        scheduled: scheduled,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingEarmarks: currentEarmarks,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds
      )
    }

    return actualBalances + forecastBalances
  }

  @concurrent
  private static func computeExpenseBreakdown(
    nonScheduled: [Transaction],
    monthEnd: Int,
    after: Date?,
    currency: Currency
  ) async -> [ExpenseBreakdown] {
    var transactions = nonScheduled.filter { $0.type == .expense }

    if let after {
      transactions = transactions.filter { $0.date >= after }
    }

    var breakdown: [String: [UUID?: MonetaryAmount]] = [:]

    for txn in transactions {
      let month = financialMonth(for: txn.date, monthEnd: monthEnd)
      let categoryId = txn.categoryId

      if breakdown[month] == nil {
        breakdown[month] = [:]
      }
      let current = breakdown[month]![categoryId] ?? .zero(currency: currency)
      breakdown[month]![categoryId] = current + txn.amount
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
    currency: Currency
  ) async -> [MonthlyIncomeExpense] {
    var transactions = nonScheduled

    if let after {
      transactions = transactions.filter { $0.date >= after }
    }

    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    var monthlyData: [String: CloudKitMonthData] = [:]

    for txn in transactions {
      guard txn.accountId != nil else { continue }
      let month = financialMonth(for: txn.date, monthEnd: monthEnd)

      if monthlyData[month] == nil {
        monthlyData[month] = CloudKitMonthData(
          start: txn.date, end: txn.date, currency: currency)
      }

      if txn.date < monthlyData[month]!.start {
        monthlyData[month]!.start = txn.date
      }
      if txn.date > monthlyData[month]!.end {
        monthlyData[month]!.end = txn.date
      }

      let isEarmarked = txn.earmarkId != nil
      let isFromInvestment = txn.accountId.map { investmentAccountIds.contains($0) } ?? false
      let isToInvestment = txn.toAccountId.map { investmentAccountIds.contains($0) } ?? false

      switch txn.type {
      case .income, .openingBalance:
        if isEarmarked {
          monthlyData[month]!.earmarkedIncome += txn.amount
        } else {
          monthlyData[month]!.income += txn.amount
        }

      case .expense:
        let absAmount = MonetaryAmount(
          cents: abs(txn.amount.cents),
          currency: txn.amount.currency
        )
        if isEarmarked {
          monthlyData[month]!.earmarkedExpense += absAmount
        } else {
          monthlyData[month]!.expense += absAmount
        }

      case .transfer:
        // Compute profit contribution matching server: +amount for from_investment,
        // -amount for to_investment. Route positive to earmarkedIncome (pool growth),
        // negative to earmarkedExpense (pool shrinkage). This handles positive-amount
        // transfers (e.g. dividend reinvestments) correctly.
        var profitContribution = 0
        if isFromInvestment && !isToInvestment {
          profitContribution = txn.amount.cents
        } else if !isFromInvestment && isToInvestment {
          profitContribution = -txn.amount.cents
        }
        if profitContribution > 0 {
          monthlyData[month]!.earmarkedIncome += MonetaryAmount(
            cents: profitContribution, currency: txn.amount.currency)
        } else if profitContribution < 0 {
          monthlyData[month]!.earmarkedExpense += MonetaryAmount(
            cents: -profitContribution, currency: txn.amount.currency)
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
        profit: data.income - data.expense,
        earmarkedIncome: data.earmarkedIncome,
        earmarkedExpense: data.earmarkedExpense,
        earmarkedProfit: data.earmarkedIncome - data.earmarkedExpense
      )
    }.sorted { $0.month > $1.month }
  }

  // MARK: - Static Helper Methods

  private static func applyTransaction(
    _ txn: Transaction,
    to balance: inout MonetaryAmount,
    investments: inout MonetaryAmount,
    earmarks: inout MonetaryAmount,
    investmentAccountIds: Set<UUID>
  ) {
    let isFromInvestment = txn.accountId.map { investmentAccountIds.contains($0) } ?? false
    let isToInvestment = txn.toAccountId.map { investmentAccountIds.contains($0) } ?? false

    switch txn.type {
    case .income, .expense, .openingBalance:
      if txn.accountId != nil {
        balance += txn.amount
      }
      if txn.earmarkId != nil {
        earmarks += txn.amount
      }

    case .transfer:
      // Match server: investments += amount for from_investment, -= amount for to_investment.
      // Balance gets the opposite. Use signed amounts, not abs(), so positive-amount
      // transfers (e.g. dividend reinvestments) are handled correctly.
      if isFromInvestment && !isToInvestment {
        balance -= txn.amount
        investments += txn.amount
      } else if !isFromInvestment && isToInvestment {
        balance += txn.amount
        investments -= txn.amount
      }
    }
  }

  private static func applyInvestmentValues(
    _ investmentValues: [(accountId: UUID, date: Date, value: MonetaryAmount)],
    to dailyBalances: inout [Date: DailyBalance],
    currency: Currency
  ) {
    guard !investmentValues.isEmpty, !dailyBalances.isEmpty else { return }

    var latestByAccount: [UUID: MonetaryAmount] = [:]
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
        let totalValue = latestByAccount.values.reduce(
          MonetaryAmount.zero(currency: currency), +)
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
  static func applyBestFit(to balances: inout [DailyBalance], currency: Currency) {
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
      let y = Double(balance.availableFunds.cents)
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
      let predicted = Int(round(m * xValues[i] + b))
      balances[i] = DailyBalance(
        date: balances[i].date,
        balance: balances[i].balance,
        earmarked: balances[i].earmarked,
        availableFunds: balances[i].availableFunds,
        investments: balances[i].investments,
        investmentValue: balances[i].investmentValue,
        netWorth: balances[i].netWorth,
        bestFit: MonetaryAmount(cents: predicted, currency: currency),
        isForecast: balances[i].isForecast
      )
    }
  }

  private static func generateForecast(
    scheduled: [Transaction],
    startDate: Date,
    endDate: Date,
    startingBalance: MonetaryAmount,
    startingEarmarks: MonetaryAmount,
    startingInvestments: MonetaryAmount,
    investmentAccountIds: Set<UUID>
  ) -> [DailyBalance] {
    // Extrapolate instances up to endDate
    var instances: [Transaction] = []
    for scheduledTxn in scheduled {
      instances.append(contentsOf: extrapolateScheduledTransaction(scheduledTxn, until: endDate))
    }

    // Sort by date and apply to running balances
    instances.sort { $0.date < $1.date }
    var balance = startingBalance
    var earmarks = startingEarmarks
    var investments = startingInvestments

    var forecastBalances: [Date: DailyBalance] = [:]
    for instance in instances {
      applyTransaction(
        instance,
        to: &balance,
        investments: &investments,
        earmarks: &earmarks,
        investmentAccountIds: investmentAccountIds
      )

      let dayKey = Calendar.current.startOfDay(for: instance.date)
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
  let currency: Currency
  var income: MonetaryAmount
  var expense: MonetaryAmount
  var earmarkedIncome: MonetaryAmount
  var earmarkedExpense: MonetaryAmount

  init(start: Date, end: Date, currency: Currency) {
    self.start = start
    self.end = end
    self.currency = currency
    self.income = .zero(currency: currency)
    self.expense = .zero(currency: currency)
    self.earmarkedIncome = .zero(currency: currency)
    self.earmarkedExpense = .zero(currency: currency)
  }
}
