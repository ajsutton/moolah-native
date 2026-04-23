import Foundation

extension CloudKitAnalysisRepository {
  // MARK: - Expense Breakdown Computation

  @concurrent
  static func computeExpenseBreakdown(
    nonScheduled: [Transaction],
    monthEnd: Int,
    after: Date?,
    context: CloudKitAnalysisContext
  ) async throws -> [ExpenseBreakdown] {
    var breakdown: [String: [UUID?: InstrumentAmount]] = [:]
    var lastFinDate: Date?
    var lastFinMonth: String = ""

    for transaction in nonScheduled {
      if let after, transaction.date < after { continue }

      let month: String
      if let last = lastFinDate, transaction.date.isSameDay(as: last) {
        month = lastFinMonth
      } else {
        month = financialMonth(for: transaction.date, monthEnd: monthEnd)
        lastFinMonth = month
        lastFinDate = transaction.date
      }

      try await accumulateExpenseLegs(
        transaction: transaction, month: month, context: context, into: &breakdown)
    }

    return flattenBreakdown(breakdown)
  }

  private static func accumulateExpenseLegs(
    transaction: Transaction,
    month: String,
    context: CloudKitAnalysisContext,
    into breakdown: inout [String: [UUID?: InstrumentAmount]]
  ) async throws {
    for leg in transaction.legs where leg.type == .expense && leg.categoryId != nil {
      let categoryId = leg.categoryId
      let amount = try await convertedAmount(
        leg,
        to: context.instrument,
        on: transaction.date,
        conversionService: context.conversionService
      )
      var monthBreakdown = breakdown[month] ?? [:]
      let current = monthBreakdown[categoryId] ?? .zero(instrument: context.instrument)
      monthBreakdown[categoryId] = current + amount
      breakdown[month] = monthBreakdown
    }
  }

  private static func flattenBreakdown(
    _ breakdown: [String: [UUID?: InstrumentAmount]]
  ) -> [ExpenseBreakdown] {
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

  // MARK: - Income and Expense Computation

  @concurrent
  static func computeIncomeAndExpense(
    nonScheduled: [Transaction],
    accounts: [Account],
    monthEnd: Int,
    after: Date?,
    context: CloudKitAnalysisContext
  ) async throws -> [MonthlyIncomeExpense] {
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))
    var monthlyData: [String: CloudKitMonthData] = [:]
    var lastFinDate: Date?
    var lastFinMonth: String = ""

    for transaction in nonScheduled {
      if let after, transaction.date < after { continue }
      guard !transaction.legs.isEmpty else { continue }

      let month: String
      if let last = lastFinDate, transaction.date.isSameDay(as: last) {
        month = lastFinMonth
      } else {
        month = financialMonth(for: transaction.date, monthEnd: monthEnd)
        lastFinMonth = month
        lastFinDate = transaction.date
      }

      var data =
        monthlyData[month]
        ?? CloudKitMonthData(
          start: transaction.date, end: transaction.date, instrument: context.instrument)
      data.start = min(data.start, transaction.date)
      data.end = max(data.end, transaction.date)

      try await accumulateLegs(
        transaction: transaction,
        investmentAccountIds: investmentAccountIds,
        context: context,
        into: &data
      )
      monthlyData[month] = data
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

  /// Apply all legs of a single transaction to the accumulating month data.
  /// Extracted to keep `computeIncomeAndExpense` below the complexity and
  /// body-length thresholds.
  private static func accumulateLegs(
    transaction: Transaction,
    investmentAccountIds: Set<UUID>,
    context: CloudKitAnalysisContext,
    into data: inout CloudKitMonthData
  ) async throws {
    for leg in transaction.legs {
      let amount = try await convertedAmount(
        leg,
        to: context.instrument,
        on: transaction.date,
        conversionService: context.conversionService
      )
      let classified = ClassifiedLeg(
        leg: leg,
        amount: amount,
        isEarmarked: leg.earmarkId != nil,
        isInvestmentAccount: leg.accountId.map(investmentAccountIds.contains) ?? false,
        instrument: context.instrument
      )
      applyLegToMonth(classified, into: &data)
    }
  }

  /// A transaction leg together with its converted amount and pre-computed
  /// classification flags. Bundling these keeps `applyLegToMonth` at a single
  /// parameter and stays under the function_parameter_count threshold.
  private struct ClassifiedLeg {
    let leg: TransactionLeg
    let amount: InstrumentAmount
    let isEarmarked: Bool
    let isInvestmentAccount: Bool
    let instrument: Instrument

    var hasAccount: Bool { leg.accountId != nil }
    var contributesToProfit: Bool {
      leg.type == .income || leg.type == .expense
    }
  }

  /// Apply a single already-converted leg amount to the monthly accumulator.
  /// Split into per-bucket helpers so this parent stays under the complexity
  /// threshold.
  private static func applyLegToMonth(
    _ classified: ClassifiedLeg,
    into data: inout CloudKitMonthData
  ) {
    applyByType(classified, into: &data)
    applyProfit(classified, into: &data)
  }

  private static func applyByType(
    _ classified: ClassifiedLeg,
    into data: inout CloudKitMonthData
  ) {
    switch classified.leg.type {
    case .income:
      // Server: SUM(IF(type='income' AND account_id IS NOT NULL, amount, 0))
      // Include in main total only when leg has an account (matching server).
      // Earmark-only income (nil accountId) goes to earmarkedIncome only.
      if classified.hasAccount {
        data.income += classified.amount
      }
      if classified.isEarmarked {
        data.earmarkedIncome += classified.amount
      }
    case .openingBalance:
      // Server excludes openingBalance from income/expense reports.
      break
    case .expense:
      // Server: SUM(IF(type='expense' AND account_id IS NOT NULL, amount, 0))
      // Expenses are negative, refunds are positive — pass through as-is to
      // match the server convention.
      if classified.hasAccount {
        data.expense += classified.amount
      }
      if classified.isEarmarked {
        data.earmarkedExpense += classified.amount
      }
    case .transfer:
      applyTransferLeg(classified, into: &data)
    }
  }

  private static func applyProfit(
    _ classified: ClassifiedLeg,
    into data: inout CloudKitMonthData
  ) {
    // Server: profit = SUM(IF(account_id IS NOT NULL AND type IN
    // ('income','expense'), amount, 0))
    // Server: earmarkedProfit = SUM(earmarked income/expense amounts) +
    // SUM(transfer adjustments)
    // Accumulate profit directly rather than deriving from income/expense,
    // because transfer contributions to earmarkedExpense use a different
    // sign convention.
    if classified.contributesToProfit {
      if classified.hasAccount {
        data.profit += classified.amount
      }
      if classified.isEarmarked {
        data.earmarkedProfit += classified.amount
      }
    } else if classified.leg.type == .transfer, classified.isInvestmentAccount {
      // Investment transfer profit = raw contribution amount.
      // Deposits (positive) add to earmarked profit; withdrawals (negative)
      // subtract.
      data.earmarkedProfit += classified.amount
    }
  }

  /// Route a transfer leg to the earmarked income/expense buckets based on
  /// its sign. Only transfers that touch an investment account contribute.
  private static func applyTransferLeg(
    _ classified: ClassifiedLeg,
    into data: inout CloudKitMonthData
  ) {
    guard classified.isInvestmentAccount else { return }
    if classified.amount.quantity > 0 {
      data.earmarkedIncome += classified.amount
    } else if classified.amount.quantity < 0 {
      data.earmarkedExpense += InstrumentAmount(
        quantity: -classified.amount.quantity, instrument: classified.instrument)
    }
  }
}
