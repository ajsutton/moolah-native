import Foundation
import SwiftData

final class CloudKitAnalysisRepository: AnalysisRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currency: Currency

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  // MARK: - Data Fetching Helpers

  private func fetchTransactions(scheduled: Bool? = nil) async throws -> [Transaction] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
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
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
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

    // 2. Filter by date range
    let transactions = allTransactions.filter { txn in
      guard let after else { return true }
      return txn.date >= after
    }

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

    // 5. Generate forecasted balances if requested
    var scheduledBalances: [DailyBalance] = []
    if let forecastUntil {
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
      if txn.accountId != nil {
        balance += txn.amount
      }
      if txn.earmarkId != nil {
        earmarks += txn.amount
      }

    case .transfer:
      if isFromInvestment && !isToInvestment {
        balance += txn.amount
        investments -= txn.amount
      } else if !isFromInvestment && isToInvestment {
        balance -= txn.amount
        investments += txn.amount
      }
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
    let scheduledTransactions = try await fetchTransactions(scheduled: true)

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
      return nil
    }

    return calendar.date(byAdding: components, to: date)
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

    for txn in transactions where txn.amount.cents < 0 {
      let month = financialMonth(for: txn.date, monthEnd: monthEnd)
      let categoryId = txn.categoryId

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
        if isFromInvestment && !isToInvestment {
          monthlyData[month]!.earmarkedExpense += MonetaryAmount(
            cents: abs(txn.amount.cents),
            currency: txn.amount.currency
          )
        } else if !isFromInvestment && isToInvestment {
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
