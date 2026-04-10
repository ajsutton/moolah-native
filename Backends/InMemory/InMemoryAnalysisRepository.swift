import Foundation

final class InMemoryAnalysisRepository: AnalysisRepository, Sendable {
  private let transactionRepository: InMemoryTransactionRepository
  private let accountRepository: InMemoryAccountRepository
  private let earmarkRepository: InMemoryEarmarkRepository
  private let investmentRepository: InMemoryInvestmentRepository
  private let currency: Currency

  init(
    transactionRepository: InMemoryTransactionRepository,
    accountRepository: InMemoryAccountRepository,
    earmarkRepository: InMemoryEarmarkRepository,
    investmentRepository: InMemoryInvestmentRepository = InMemoryInvestmentRepository(),
    currency: Currency = .AUD
  ) {
    self.transactionRepository = transactionRepository
    self.accountRepository = accountRepository
    self.earmarkRepository = earmarkRepository
    self.investmentRepository = investmentRepository
    self.currency = currency
  }

  // MARK: - Daily Balances

  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    // 1. Fetch all non-scheduled transactions (use large page size for in-memory backend)
    let filter = TransactionFilter(scheduled: false)
    let page = try await transactionRepository.fetch(filter: filter, page: 0, pageSize: 10000)
    let allTransactions = page.transactions

    // 2. Filter by date range
    let transactions = allTransactions.filter { txn in
      guard let after = after else { return true }
      return txn.date >= after
    }

    // 3. Get accounts to classify as current vs investment
    let accounts = try await accountRepository.fetchAll()
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    // 4. Compute daily balances
    var dailyBalances: [Date: DailyBalance] = [:]
    var currentBalance: MonetaryAmount = .zero(currency: currency)
    var currentInvestments: MonetaryAmount = .zero(currency: currency)
    var currentEarmarks: MonetaryAmount = .zero(currency: currency)

    // If 'after' is provided, compute starting balances up to that date
    if let after = after {
      let priorFilter = TransactionFilter(scheduled: false)
      let priorPage = try await transactionRepository.fetch(
        filter: priorFilter, page: 0, pageSize: 10000)
      let priorTransactions = priorPage.transactions.filter { $0.date < after }

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

    // Apply each transaction to running balances
    for txn in transactions.sorted(by: { $0.date < $1.date }) {
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

    // 5. Apply investment values from investment repository
    let investmentAccountIdsList = Array(investmentAccountIds)
    let allInvestmentValues = try await fetchAllInvestmentValues(
      accountIds: investmentAccountIdsList)
    applyInvestmentValues(allInvestmentValues, to: &dailyBalances, currency: currency)

    // 6. Compute bestFit (linear regression on availableFunds)
    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    InMemoryAnalysisRepository.applyBestFit(to: &actualBalances, currency: currency)

    // 7. Generate forecasted balances if requested
    var scheduledBalances: [DailyBalance] = []
    if let forecastUntil = forecastUntil {
      let lastDate = transactions.last?.date ?? Date()
      scheduledBalances = try await generateForecast(
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

  /// Fetch all investment values across the given accounts, sorted by date ascending.
  private func fetchAllInvestmentValues(accountIds: [UUID]) async throws -> [(
    accountId: UUID, date: Date, value: MonetaryAmount
  )] {
    var allValues: [(accountId: UUID, date: Date, value: MonetaryAmount)] = []
    for accountId in accountIds {
      let page = try await investmentRepository.fetchValues(
        accountId: accountId, page: 0, pageSize: 10000)
      for iv in page.values {
        allValues.append((accountId: accountId, date: iv.date, value: iv.value))
      }
    }
    return allValues.sorted { $0.date < $1.date }
  }

  /// Apply investment values to daily balances.
  /// For each date with a daily balance, computes the total investment value
  /// by finding the most recent value entry for each investment account.
  private func applyInvestmentValues(
    _ investmentValues: [(accountId: UUID, date: Date, value: MonetaryAmount)],
    to dailyBalances: inout [Date: DailyBalance],
    currency: Currency
  ) {
    guard !investmentValues.isEmpty, !dailyBalances.isEmpty else { return }

    // Build sorted list of (date, accountId, value) for efficient lookup
    // For each account, track the most recent value as of each date
    var latestByAccount: [UUID: MonetaryAmount] = [:]
    var valueIndex = 0

    for date in dailyBalances.keys.sorted() {
      // Advance through investment values up to this date
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

      // Sum latest values across all accounts
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

    // Convert to (x, y) pairs where x = days since first date, y = availableFunds in cents
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

    // Linear regression: y = mx + b
    let denominator = n * sumXX - sumX * sumX
    guard abs(denominator) > 0.001 else { return }  // Avoid division by zero (all same date)

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

  private func applyTransaction(
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
      // Only count if accountId is non-nil (completed transaction)
      if txn.accountId != nil {
        balance += txn.amount  // income/openingBalance: positive, expense: negative
      }
      if txn.earmarkId != nil {
        earmarks += txn.amount
      }

    case .transfer:
      // Transfer: amount is always from the perspective of accountId (negative = money leaving)
      // Use abs to work with unsigned magnitudes regardless of amount sign.
      let transferMagnitude = MonetaryAmount(
        cents: abs(txn.amount.cents), currency: txn.amount.currency)
      if isFromInvestment && !isToInvestment {
        // From investment to current: increase balance, decrease investments
        balance += transferMagnitude
        investments -= transferMagnitude
      } else if !isFromInvestment && isToInvestment {
        // From current to investment: decrease balance, increase investments
        balance -= transferMagnitude
        investments += transferMagnitude
      }
    // Current-to-current transfers are net-zero on balance
    }
  }

  private func generateForecast(
    startDate: Date,
    endDate: Date,
    startingBalance: MonetaryAmount,
    startingEarmarks: MonetaryAmount,
    startingInvestments: MonetaryAmount,
    investmentAccountIds: Set<UUID>
  ) async throws -> [DailyBalance] {
    // 1. Fetch all scheduled transactions
    let scheduledFilter = TransactionFilter(scheduled: true)
    let page = try await transactionRepository.fetch(
      filter: scheduledFilter, page: 0, pageSize: 10000)
    let scheduledTransactions = page.transactions

    // 2. Extrapolate instances up to endDate
    var instances: [Transaction] = []
    for scheduled in scheduledTransactions {
      instances.append(contentsOf: extrapolateScheduledTransaction(scheduled, until: endDate))
    }

    // 3. Sort by date and apply to running balances
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

  private func extrapolateScheduledTransaction(
    _ scheduled: Transaction,
    until endDate: Date
  ) -> [Transaction] {
    guard let period = scheduled.recurPeriod, period != .once else {
      // One-time scheduled transactions: single instance if date <= endDate
      return scheduled.date <= endDate ? [scheduled] : []
    }

    let every = scheduled.recurEvery ?? 1
    var instances: [Transaction] = []
    var currentDate = scheduled.date

    while currentDate <= endDate {
      var instance = scheduled
      instance.date = currentDate
      instance.recurPeriod = nil  // Instances are not scheduled
      instance.recurEvery = nil
      instances.append(instance)

      // Calculate next occurrence
      guard let nextDate = nextDueDate(from: currentDate, period: period, every: every) else {
        break
      }
      currentDate = nextDate
    }

    return instances
  }

  private func nextDueDate(from date: Date, period: RecurPeriod, every: Int) -> Date? {
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
      return nil  // No recurrence
    }

    return calendar.date(byAdding: components, to: date)
  }

  // MARK: - Expense Breakdown

  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown] {
    // 1. Fetch all non-scheduled transactions
    let filter = TransactionFilter(scheduled: false)
    let page = try await transactionRepository.fetch(filter: filter, page: 0, pageSize: 10000)
    var transactions = page.transactions.filter { $0.type == .expense }

    // 2. Filter by date range
    if let after = after {
      transactions = transactions.filter { $0.date >= after }
    }

    // 3. Group by (categoryId, financialMonth)
    var breakdown: [String: [UUID?: MonetaryAmount]] = [:]  // [month: [categoryId: total]]

    for txn in transactions where txn.amount.cents < 0 {
      let categoryId = txn.categoryId
      let month = financialMonth(for: txn.date, monthEnd: monthEnd)

      if breakdown[month] == nil {
        breakdown[month] = [:]
      }
      let current = breakdown[month]![categoryId] ?? .zero(currency: currency)
      breakdown[month]![categoryId] =
        current
        + MonetaryAmount(
          cents: abs(txn.amount.cents),
          currency: txn.amount.currency
        )
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

    return results.sorted { $0.month > $1.month }  // Most recent first
  }

  // MARK: - Income and Expense

  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    // 1. Fetch all non-scheduled transactions
    let filter = TransactionFilter(scheduled: false)
    let page = try await transactionRepository.fetch(filter: filter, page: 0, pageSize: 10000)
    var transactions = page.transactions

    // 2. Filter by date range
    if let after = after {
      transactions = transactions.filter { $0.date >= after }
    }

    // 3. Get investment account IDs
    let accounts = try await accountRepository.fetchAll()
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    // 4. Group by financial month
    var monthlyData: [String: MonthData] = [:]

    for txn in transactions {
      guard txn.accountId != nil else { continue }  // Only completed transactions
      let month = financialMonth(for: txn.date, monthEnd: monthEnd)

      // Initialize month entry
      if monthlyData[month] == nil {
        monthlyData[month] = MonthData(start: txn.date, end: txn.date, currency: currency)
      }

      // Update date range
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
        if isFromInvestment && !isToInvestment {
          // From investment to current: earmarked expense (returning funds)
          monthlyData[month]!.earmarkedExpense += MonetaryAmount(
            cents: abs(txn.amount.cents),
            currency: txn.amount.currency
          )
        } else if !isFromInvestment && isToInvestment {
          // From current to investment: earmarked income (allocating funds)
          monthlyData[month]!.earmarkedIncome += MonetaryAmount(
            cents: abs(txn.amount.cents),
            currency: txn.amount.currency
          )
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
    }.sorted { $0.month > $1.month }  // Most recent first
  }

  // MARK: - Category Balances

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?
  ) async throws -> [UUID: MonetaryAmount] {
    // 1. Fetch all transactions
    let page = try await transactionRepository.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 10000)
    let allTransactions = page.transactions

    // 2. Apply filters
    let filtered = allTransactions.filter { tx in
      // Date range
      guard dateRange.contains(tx.date) else { return false }

      // Transaction type
      guard tx.type == transactionType else { return false }

      // Must have category
      guard tx.categoryId != nil else { return false }

      // Exclude scheduled transactions
      guard tx.recurPeriod == nil else { return false }

      // Apply optional filters
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

  // MARK: - Helper Methods

  private func financialMonth(for date: Date, monthEnd: Int) -> String {
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

// Helper struct for building monthly data
private struct MonthData {
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
