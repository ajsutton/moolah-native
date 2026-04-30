import Foundation

/// Computes the effective annual rate for a stream of contributions and a
/// terminal value, using Newton–Raphson seeded by Modified Dietz with a
/// bisection fallback for pathological multi-root cases.
///
/// Day-precise: contribution exponents are `−tᵢ / 365` where `tᵢ` is days
/// from the first flow. Replaces the legacy 30-day-month / monthly-rate-as-
/// percent approximations in `InvestmentStore.annualizedReturnRate`.
///
/// **Returns `nil` when:**
/// - `flows` is empty,
/// - the span between the first flow and `terminalDate` is < 1 day
///   (cannot annualise meaningfully),
/// - Newton–Raphson fails to converge in 50 iterations *and* bisection
///   fallback over `[−0.99, 10.0]` also fails.
///
/// Internally evaluates `(1 + r)^(−t/365)` in `Double` (Decimal has no
/// fractional `pow`) and returns the converged rate as `Decimal` at the
/// boundary so callers can mix it with money-typed math without lossy
/// further conversions.
enum IRRSolver {
  /// One contribution converted to the (daysFromFirst, signedAmount) form
  /// the solver iterates over.
  private struct DayFlow {
    let daysFromFirst: Double
    let amount: Double
  }

  /// Returns the effective annual rate for the given cash flows, or `nil`
  /// if the rate cannot be determined. See `IRRSolver` type documentation
  /// for nil-return conditions and the Double/Decimal boundary rationale.
  static func annualisedReturn(
    flows: [CashFlow],
    terminalValue: Decimal,
    terminalDate: Date
  ) -> Decimal? {
    guard let first = flows.first else { return nil }
    let totalDays = terminalDate.timeIntervalSince(first.date) / 86_400
    guard totalDays >= 1 else { return nil }

    let terminal = (terminalValue as NSDecimalNumber).doubleValue
    let dayFlows: [DayFlow] = flows.map { flow in
      let days = flow.date.timeIntervalSince(first.date) / 86_400
      return DayFlow(
        daysFromFirst: days,
        amount: (flow.amount as NSDecimalNumber).doubleValue
      )
    }

    let seed = modifiedDietzAnnualised(
      dayFlows: dayFlows,
      terminal: terminal,
      totalDays: totalDays
    )
    if let rate = newtonRaphson(
      seed: seed,
      dayFlows: dayFlows,
      terminal: terminal,
      totalDays: totalDays
    ) {
      return Decimal(rate)
    }
    if let rate = bisection(
      dayFlows: dayFlows,
      terminal: terminal,
      totalDays: totalDays
    ) {
      return Decimal(rate)
    }
    return nil
  }

  /// `f(r) = Σ Cᵢ · (1+r)^(−tᵢ/365) − V · (1+r)^(−T/365)`. Returns `.nan`
  /// when `1 + rate ≤ 0` so callers know to treat the rate as out-of-domain.
  private static func npv(
    rate: Double,
    dayFlows: [DayFlow],
    terminal: Double,
    totalDays: Double
  ) -> Double {
    let onePlusR = 1 + rate
    guard onePlusR > 0 else { return .nan }
    var sum = 0.0
    for flow in dayFlows {
      sum += flow.amount * pow(onePlusR, -flow.daysFromFirst / 365)
    }
    return sum - terminal * pow(onePlusR, -totalDays / 365)
  }

  /// `(V − ΣCᵢ) / Σ(wᵢ · Cᵢ)` annualised to `(1 + MD)^(365/T) − 1`.
  /// Returns 0 if the weighted-capital denominator is zero (degenerate input).
  private static func modifiedDietzAnnualised(
    dayFlows: [DayFlow],
    terminal: Double,
    totalDays: Double
  ) -> Double {
    var sumC = 0.0
    var sumWeightedC = 0.0
    for flow in dayFlows {
      sumC += flow.amount
      let weight = (totalDays - flow.daysFromFirst) / totalDays
      sumWeightedC += weight * flow.amount
    }
    guard sumWeightedC != 0 else { return 0 }
    let dietz = (terminal - sumC) / sumWeightedC
    return pow(1 + dietz, 365 / totalDays) - 1
  }

  /// Applies Newton–Raphson to `npv(rate:dayFlows:terminal:totalDays:)` seeded
  /// at `seed`. Stops when `|f| < 1e-9` or 50 iterations elapsed. Returns
  /// `nil` on divergence.
  private static func newtonRaphson(
    seed: Double,
    dayFlows: [DayFlow],
    terminal: Double,
    totalDays: Double
  ) -> Double? {
    var rate = seed
    for _ in 0..<50 {
      let onePlusR = 1 + rate
      let fValue = npv(rate: rate, dayFlows: dayFlows, terminal: terminal, totalDays: totalDays)
      if fValue.isNaN { return nil }
      var fPrime = 0.0
      for flow in dayFlows {
        let exponent = -flow.daysFromFirst / 365
        let powered = pow(onePlusR, exponent)
        fPrime += flow.amount * exponent * powered / onePlusR
      }
      let terminalExponent = -totalDays / 365
      let terminalPower = pow(onePlusR, terminalExponent)
      fPrime -= terminal * terminalExponent * terminalPower / onePlusR

      if abs(fValue) < 1e-9 { return rate }
      guard fPrime != 0 else { return nil }
      rate -= fValue / fPrime
    }
    return nil
  }

  /// Sign-change bisection search over `[−0.99, 10.0]`. Last-resort fallback
  /// for multi-root patterns that throw Newton-Raphson off. Terminates when
  /// `|f| < 1e-9` or the 60-step bound is reached (≈ `1e-17` interval width).
  private static func bisection(
    dayFlows: [DayFlow],
    terminal: Double,
    totalDays: Double
  ) -> Double? {
    var low = -0.99
    var high = 10.0
    var fLow = npv(rate: low, dayFlows: dayFlows, terminal: terminal, totalDays: totalDays)
    let fHigh = npv(rate: high, dayFlows: dayFlows, terminal: terminal, totalDays: totalDays)
    if fLow.isNaN || fHigh.isNaN { return nil }
    if fLow * fHigh > 0 { return nil }
    for _ in 0..<60 {
      let mid = (low + high) / 2
      let fMid = npv(rate: mid, dayFlows: dayFlows, terminal: terminal, totalDays: totalDays)
      if fMid.isNaN { return nil }
      if abs(fMid) < 1e-9 { return mid }
      if fLow * fMid < 0 {
        high = mid
      } else {
        low = mid
        fLow = fMid
      }
    }
    return (low + high) / 2
  }
}
