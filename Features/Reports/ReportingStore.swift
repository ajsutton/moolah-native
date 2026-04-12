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
    max(0, longTermGain) * Decimal(string: "0.5")!
  }

  /// Net capital gain after applying CGT discount (losses offset gains before discount).
  var netCapitalGain: Decimal {
    let netShortTerm = shortTermGain
    let netLongTerm = longTermGain > 0 ? discountedLongTermGain : longTermGain
    return max(0, netShortTerm + netLongTerm)
  }
}

extension CapitalGainsSummary {
  /// Convert to values suitable for TaxYearAdjustments fields.
  ///
  /// Maps to:
  /// - `shortTerm`: gains from assets held < 12 months
  /// - `longTerm`: pre-discount gains from assets held > 12 months
  /// - `losses`: absolute value of net losses (if total is negative)
  func asTaxAdjustmentValues(currency: Instrument) -> (
    shortTerm: InstrumentAmount,
    longTerm: InstrumentAmount,
    losses: InstrumentAmount
  ) {
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
    return (shortTerm, longTerm, losses)
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

  private let transactionRepository: TransactionRepository
  private let conversionService: InstrumentConversionService
  private let profileCurrency: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "ReportingStore")

  init(
    transactionRepository: TransactionRepository,
    conversionService: InstrumentConversionService,
    profileCurrency: Instrument
  ) {
    self.transactionRepository = transactionRepository
    self.conversionService = conversionService
    self.profileCurrency = profileCurrency
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
      let fyStart = calendar.date(from: DateComponents(year: financialYear - 1, month: 7, day: 1))!
      let fyEnd = calendar.date(from: DateComponents(year: financialYear, month: 6, day: 30))!

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
