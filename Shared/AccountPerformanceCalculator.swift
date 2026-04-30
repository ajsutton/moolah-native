import Foundation
import OSLog

/// Pure orchestrator that turns transactions + valued positions into an
/// `AccountPerformance`.
///
/// Two entry points (`computeLegacy` ships in Task 7):
/// - `compute(...)` for position-tracked accounts. Uses the §2 boundary-
///   crossing rule from the design spec to extract `CashFlow`s, throws on
///   conversion failure (Rule 11 — partial sums are forbidden).
///
/// Both entry points share `IRRSolver` for the annualised rate and the
/// same Modified Dietz formula for `profitLossPercent`.
enum AccountPerformanceCalculator {
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "AccountPerformanceCalculator")

  // MARK: - Position-tracked

  /// Computes account-level performance for a position-tracked investment
  /// account. Throws when any cash-flow currency conversion fails — per
  /// Rule 11 the caller should treat the entire performance as
  /// unavailable, not partially populated.
  static func compute(
    accountId: UUID,
    transactions: [Transaction],
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> AccountPerformance {
    let flows = try await extractFlows(
      from: transactions,
      accountId: accountId,
      profileCurrency: profileCurrency,
      conversionService: conversionService)

    let currentValue = aggregatedValue(of: valuedPositions, in: profileCurrency)

    return assemble(
      flows: flows,
      currentValue: currentValue,
      profileCurrency: profileCurrency,
      now: Date())
  }

  /// §2 cash-flow extraction. A leg L in `accountId` produces one
  /// `CashFlow` iff (a) `L.type == .openingBalance`, OR (b) the
  /// transaction crosses an account boundary (some other leg references a
  /// different non-nil account). Rationale: any boundary-crossing
  /// transaction moves capital regardless of leg type, while pure intra-
  /// account activity (trades, dividends, fees) is reflected via the
  /// account's terminal value rather than as a flow.
  private static func extractFlows(
    from transactions: [Transaction],
    accountId: UUID,
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CashFlow] {
    var flows: [CashFlow] = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for transaction in sorted {
      let otherAccountIds = Set(transaction.legs.compactMap(\.accountId))
        .subtracting([accountId])
      let crossesBoundary = !otherAccountIds.isEmpty
      for leg in transaction.legs where leg.accountId == accountId {
        guard leg.type == .openingBalance || crossesBoundary else { continue }
        let amountInProfileCurrency: Decimal
        if leg.instrument == profileCurrency {
          amountInProfileCurrency = leg.quantity
        } else {
          amountInProfileCurrency = try await conversionService.convert(
            leg.quantity, from: leg.instrument, to: profileCurrency, on: transaction.date)
        }
        flows.append(CashFlow(date: transaction.date, amount: amountInProfileCurrency))
      }
    }
    return flows
  }

  /// Sum of valued positions in `profileCurrency`, or `nil` if any row's
  /// `value` is missing — Rule 11 forbids partial sums.
  private static func aggregatedValue(
    of valued: [ValuedPosition], in profileCurrency: Instrument
  ) -> InstrumentAmount? {
    var total = InstrumentAmount.zero(instrument: profileCurrency)
    for row in valued {
      guard let value = row.value else { return nil }
      total += value
    }
    return total
  }

  /// Assembles the final `AccountPerformance` from extracted flows and
  /// the aggregated terminal value. Centralised so Task 7's
  /// `computeLegacy` reuses the same formulae.
  private static func assemble(
    flows: [CashFlow],
    currentValue: InstrumentAmount?,
    profileCurrency: Instrument,
    now: Date
  ) -> AccountPerformance {
    guard let currentValue else {
      return .unavailable(in: profileCurrency)
    }
    guard let firstFlow = flows.first else {
      return AccountPerformance(
        instrument: profileCurrency,
        currentValue: currentValue,
        totalContributions: .zero(instrument: profileCurrency),
        profitLoss: .zero(instrument: profileCurrency),
        profitLossPercent: nil,
        annualisedReturn: nil,
        firstFlowDate: nil)
    }

    let totalContributions = flows.reduce(Decimal(0)) { $0 + $1.amount }
    let terminal = Double(truncating: currentValue.quantity as NSDecimalNumber)
    let totalDays = max(now.timeIntervalSince(firstFlow.date) / 86_400, 0)

    let plQuantity = currentValue.quantity - totalContributions
    let plPercent = modifiedDietzPercent(
      flows: flows, terminal: terminal, totalDays: totalDays)
    let annualised = IRRSolver.annualisedReturn(
      flows: flows, terminalValue: currentValue.quantity, terminalDate: now)

    return AccountPerformance(
      instrument: profileCurrency,
      currentValue: currentValue,
      totalContributions: InstrumentAmount(
        quantity: totalContributions, instrument: profileCurrency),
      profitLoss: InstrumentAmount(quantity: plQuantity, instrument: profileCurrency),
      profitLossPercent: plPercent,
      annualisedReturn: annualised,
      firstFlowDate: firstFlow.date)
  }

  /// `(V − ΣCᵢ) / Σ(wᵢ · Cᵢ)` with `wᵢ = (T − tᵢ) / T`. Same formula
  /// `IRRSolver` uses internally as its Newton-Raphson seed; we expose it
  /// here so the result is shown directly as the period return without
  /// re-deriving it from `IRRSolver`'s annualised output.
  ///
  /// Returns `nil` for spans < 1 day or zero weighted-capital.
  private static func modifiedDietzPercent(
    flows: [CashFlow], terminal: Double, totalDays: Double
  ) -> Decimal? {
    guard totalDays >= 1 else { return nil }
    let firstDate = flows[0].date
    var contributionSum = 0.0
    var weightedSum = 0.0
    for flow in flows {
      let days = flow.date.timeIntervalSince(firstDate) / 86_400
      let weight = (totalDays - days) / totalDays
      let amount = Double(truncating: flow.amount as NSDecimalNumber)
      contributionSum += amount
      weightedSum += weight * amount
    }
    guard weightedSum != 0 else { return nil }
    return Decimal((terminal - contributionSum) / weightedSum)
  }
}
