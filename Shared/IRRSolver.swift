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
  static func annualisedReturn(
    flows: [CashFlow],
    terminalValue: Decimal,
    terminalDate: Date
  ) -> Decimal? {
    guard let first = flows.first else { return nil }
    let totalDays = terminalDate.timeIntervalSince(first.date) / 86_400
    guard totalDays >= 1 else { return nil }

    let v = (terminalValue as NSDecimalNumber).doubleValue
    let cashflows: [(t: Double, c: Double)] = flows.map { flow in
      let days = flow.date.timeIntervalSince(first.date) / 86_400
      return (t: days, c: (flow.amount as NSDecimalNumber).doubleValue)
    }

    let seed = modifiedDietzAnnualised(cashflows: cashflows, v: v, totalDays: totalDays)
    if let r = newtonRaphson(seed: seed, cashflows: cashflows, v: v, totalDays: totalDays) {
      return Decimal(r)
    }
    if let r = bisection(cashflows: cashflows, v: v, totalDays: totalDays) {
      return Decimal(r)
    }
    return nil
  }

  /// `(V − ΣCᵢ) / Σ(wᵢ · Cᵢ)` annualised to `(1 + MD)^(365/T) − 1`.
  /// Returns 0 if the weighted-capital denominator is zero (degenerate input).
  private static func modifiedDietzAnnualised(
    cashflows: [(t: Double, c: Double)],
    v: Double,
    totalDays: Double
  ) -> Double {
    var sumC = 0.0
    var sumWeightedC = 0.0
    for f in cashflows {
      sumC += f.c
      let weight = (totalDays - f.t) / totalDays
      sumWeightedC += weight * f.c
    }
    guard sumWeightedC != 0 else { return 0 }
    let md = (v - sumC) / sumWeightedC
    return pow(1 + md, 365 / totalDays) - 1
  }

  /// `f(r) = Σ Cᵢ · (1+r)^(−tᵢ/365) − V · (1+r)^(−T/365)`. Stops when
  /// `|f| < 1e-9` or 50 iterations elapsed. Returns `nil` on divergence.
  private static func newtonRaphson(
    seed: Double,
    cashflows: [(t: Double, c: Double)],
    v: Double,
    totalDays: Double
  ) -> Double? {
    var r = seed
    for _ in 0..<50 {
      let one_r = 1 + r
      guard one_r > 0 else { return nil }
      var f = 0.0
      var fPrime = 0.0
      for cf in cashflows {
        let exp = -cf.t / 365
        let p = pow(one_r, exp)
        f += cf.c * p
        fPrime += cf.c * exp * p / one_r
      }
      let expV = -totalDays / 365
      let pV = pow(one_r, expV)
      f -= v * pV
      fPrime -= v * expV * pV / one_r

      if abs(f) < 1e-9 { return r }
      guard fPrime != 0 else { return nil }
      r -= f / fPrime
    }
    return nil
  }

  /// Sign-change search over `[−0.99, 10.0]`, ~30 iterations. Last-resort
  /// fallback for multi-root patterns that throw NR off.
  private static func bisection(
    cashflows: [(t: Double, c: Double)],
    v: Double,
    totalDays: Double
  ) -> Double? {
    func f(_ r: Double) -> Double {
      let one_r = 1 + r
      guard one_r > 0 else { return .nan }
      var sum = 0.0
      for cf in cashflows {
        sum += cf.c * pow(one_r, -cf.t / 365)
      }
      return sum - v * pow(one_r, -totalDays / 365)
    }
    var lo = -0.99
    var hi = 10.0
    var fLo = f(lo)
    var fHi = f(hi)
    if fLo.isNaN || fHi.isNaN { return nil }
    if fLo * fHi > 0 { return nil }
    for _ in 0..<60 {
      let mid = (lo + hi) / 2
      let fMid = f(mid)
      if fMid.isNaN { return nil }
      if abs(fMid) < 1e-9 { return mid }
      if fLo * fMid < 0 {
        hi = mid
        fHi = fMid
      } else {
        lo = mid
        fLo = fMid
      }
    }
    return (lo + hi) / 2
  }
}
