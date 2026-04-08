import Foundation

final class InMemoryAnalysisRepository: AnalysisRepository {
  private let transactionRepository: InMemoryTransactionRepository
  private let accountRepository: InMemoryAccountRepository
  private let earmarkRepository: InMemoryEarmarkRepository

  init(
    transactionRepository: InMemoryTransactionRepository,
    accountRepository: InMemoryAccountRepository,
    earmarkRepository: InMemoryEarmarkRepository
  ) {
    self.transactionRepository = transactionRepository
    self.accountRepository = accountRepository
    self.earmarkRepository = earmarkRepository
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
    var currentBalance: MonetaryAmount = .zero
    var currentInvestments: MonetaryAmount = .zero
    var currentEarmarks: MonetaryAmount = .zero

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
        investmentValue: nil,  // Not computed in-memory
        netWorth: currentBalance + currentInvestments,
        bestFit: nil,  // Not computed in-memory
        isForecast: false
      )
    }

    // 5. Generate forecasted balances if requested
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

    // 6. Combine and return
    let actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    return actualBalances + scheduledBalances
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
      // Transfer: amount is always from the perspective of accountId
      if isFromInvestment && !isToInvestment {
        // From investment to current: increase balance, decrease investments
        balance += txn.amount
        investments -= txn.amount
      } else if !isFromInvestment && isToInvestment {
        // From current to investment: decrease balance, increase investments
        balance -= txn.amount
        investments += txn.amount
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
      let month = financialMonth(for: txn.date, monthEnd: monthEnd)
      let categoryId = txn.categoryId

      if breakdown[month] == nil {
        breakdown[month] = [:]
      }
      let current = breakdown[month]![categoryId] ?? .zero
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
        monthlyData[month] = MonthData(start: txn.date, end: txn.date)
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
  var income: MonetaryAmount = .zero
  var expense: MonetaryAmount = .zero
  var earmarkedIncome: MonetaryAmount = .zero
  var earmarkedExpense: MonetaryAmount = .zero
}
