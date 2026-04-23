import Foundation
import OSLog
import Observation

/// Summary of capital gains for a financial year.
struct CapitalGainsSummary: Sendable {
  let shortTermGain: Decimal
  let longTermGain: Decimal
  let totalGain: Decimal
  let eventCount: Int

  /// Australian CGT discount: 50% on long-term gains for individuals.
  var discountedLongTermGain: Decimal {
    max(0, longTermGain) / 2
  }

  /// Net capital gain after applying CGT discount (losses offset gains before discount).
  var netCapitalGain: Decimal {
    let netShortTerm = shortTermGain
    let netLongTerm = longTermGain > 0 ? discountedLongTermGain : longTermGain
    return max(0, netShortTerm + netLongTerm)
  }
}

/// Capital-gains values in a form suitable for populating
/// `TaxYearAdjustments` fields.
///
/// - `shortTerm`: gains from assets held < 12 months
/// - `longTerm`: pre-discount gains from assets held > 12 months
/// - `losses`: absolute value of net losses (if total is negative)
struct TaxAdjustmentValues {
  let shortTerm: InstrumentAmount
  let longTerm: InstrumentAmount
  let losses: InstrumentAmount
}

extension CapitalGainsSummary {
  /// Convert to values suitable for `TaxYearAdjustments` fields.
  func asTaxAdjustmentValues(currency: Instrument) -> TaxAdjustmentValues {
    let shortTerm = InstrumentAmount(
      quantity: max(0, shortTermGain), instrument: currency
    )
    let longTerm = InstrumentAmount(
      quantity: max(0, longTermGain), instrument: currency
    )
    let totalLoss = min(0, shortTermGain) + min(0, longTermGain)
    let losses = InstrumentAmount(
      quantity: abs(totalLoss), instrument: currency
    )
    return TaxAdjustmentValues(shortTerm: shortTerm, longTerm: longTerm, losses: losses)
  }
}

@Observable
@MainActor
final class ReportingStore {
  // Published state
  private(set) var profitLoss: [InstrumentProfitLoss] = []
  private(set) var capitalGainsResult: CapitalGainsResult?
  private(set) var capitalGainsSummary: CapitalGainsSummary?
  private(set) var isLoading = false
  private(set) var error: Error?

  /// Category balances for the Reports view, bucketed by transaction type.
  private(set) var incomeBalances: [UUID: InstrumentAmount] = [:]
  private(set) var expenseBalances: [UUID: InstrumentAmount] = [:]
  private(set) var isLoadingCategoryBalances = false
  private(set) var categoryBalancesError: Error?

  private let transactionRepository: TransactionRepository
  private let analysisRepository: AnalysisRepository?
  private let conversionService: InstrumentConversionService
  private(set) var profileCurrency: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "ReportingStore")

  init(
    transactionRepository: TransactionRepository,
    analysisRepository: AnalysisRepository? = nil,
    conversionService: InstrumentConversionService,
    profileCurrency: Instrument
  ) {
    self.transactionRepository = transactionRepository
    self.analysisRepository = analysisRepository
    self.conversionService = conversionService
    self.profileCurrency = profileCurrency
  }

  /// Loads income + expense category balances for a date range. Results are
  /// published to `incomeBalances` / `expenseBalances`; failures land on
  /// `categoryBalancesError`.
  func loadCategoryBalances(dateRange: ClosedRange<Date>) async {
    guard let analysisRepository else {
      logger.error("loadCategoryBalances called without analysisRepository")
      return
    }
    isLoadingCategoryBalances = true
    categoryBalancesError = nil
    do {
      let result = try await analysisRepository.fetchCategoryBalancesByType(
        dateRange: dateRange,
        filters: TransactionFilter(),
        targetInstrument: profileCurrency
      )
      incomeBalances = result.income
      expenseBalances = result.expense
    } catch {
      logger.error("Failed to load category balances: \(error)")
      categoryBalancesError = error
    }
    isLoadingCategoryBalances = false
  }

  func loadProfitLoss() async {
    isLoading = true
    error = nil
    do {
      let transactions = try await loadAllLegTransactions()
      profitLoss = try await ProfitLossCalculator.compute(
        transactions: transactions,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        asOfDate: Date()
      )
    } catch {
      logger.error("Failed to load P&L: \(error)")
      self.error = error
    }
    isLoading = false
  }

  /// Load capital gains for an Australian financial year (1 Jul to 30 Jun).
  func loadCapitalGains(financialYear: Int) async {
    isLoading = true
    error = nil
    do {
      let transactions = try await loadAllLegTransactions()

      // Australian FY: 1 July (year-1) to 30 June (year)
      let calendar = Calendar(identifier: .gregorian)
      guard
        let fyStart = calendar.date(
          from: DateComponents(year: financialYear - 1, month: 7, day: 1)),
        let fyEnd = calendar.date(
          from: DateComponents(year: financialYear, month: 6, day: 30))
      else {
        logger.error("Could not compute financial year \(financialYear) date range")
        isLoading = false
        return
      }

      let result = try await CapitalGainsCalculator.computeWithConversion(
        transactions: transactions,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        sellDateRange: fyStart...fyEnd
      )
      capitalGainsResult = result
      capitalGainsSummary = CapitalGainsSummary(
        shortTermGain: result.shortTermGain,
        longTermGain: result.longTermGain,
        totalGain: result.totalRealizedGain,
        eventCount: result.events.count
      )
    } catch {
      logger.error("Failed to load capital gains: \(error)")
      self.error = error
    }
    isLoading = false
  }

  // MARK: - Private

  private func loadAllLegTransactions() async throws -> [LegTransaction] {
    let page = try await transactionRepository.fetch(
      filter: TransactionFilter(), page: 0, pageSize: Int.max
    )
    return page.transactions.map { tx in
      LegTransaction(date: tx.date, legs: tx.legs)
    }
  }
}
