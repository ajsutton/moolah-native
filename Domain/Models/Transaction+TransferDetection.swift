import Foundation

// Transfer-detection eligibility predicate (Extension A from
// `plans/2026-04-18-transfer-detection-design.md`, added alongside the
// crypto wallet importer in `plans/2026-05-05-crypto-wallet-import-design.md`).
//
// Eligibility lets multi-leg crypto transactions (transfer leg + cross-
// instrument fee leg) participate in the standard amount/instrument/date
// suggestion pass without false-pairing trades or already-merged
// transfers. Detection's amount/instrument matching always operates on
// the value-bearing leg.
extension Transaction {
  /// `true` iff this transaction can participate in the transfer-
  /// detection suggestion pass. Detection always operates on the value-
  /// bearing leg.
  ///
  /// Eligible shapes:
  /// - Exactly one `.transfer` leg (the value-bearing leg). Any number
  ///   of additional `.expense` legs in a different instrument from the
  ///   value-bearing leg are permitted (fees: gas, broker fees, …).
  /// - Exactly one `.income` or `.expense` leg (legacy single-leg cash).
  ///   Any number of additional `.expense` legs in a different instrument
  ///   from the value-bearing leg are permitted.
  ///
  /// Ineligible shapes:
  /// - Trades (two `.trade` legs).
  /// - Already-merged transfers (two `.transfer` legs).
  /// - Opening balances (`.openingBalance`).
  /// - Anything else with multiple value-bearing legs or with extra legs
  ///   in the same instrument as the value-bearing leg.
  var isTransferDetectionEligible: Bool { transferDetectionValueLeg != nil }

  /// The leg that detection should pair on, or `nil` when this
  /// transaction is ineligible.
  var transferDetectionValueLeg: TransactionLeg? {
    let transferLegs = legs.filter { $0.type == .transfer }
    if transferLegs.count == 1 {
      return Self.valueLegIfFeesAreCrossInstrument(
        valueLeg: transferLegs[0],
        otherLegs: legs.filter { $0.type != .transfer })
    }

    if transferLegs.isEmpty {
      let cashLegs = legs.filter { $0.type == .income || $0.type == .expense }
      // Pick the single value-bearing leg as the largest-magnitude one
      // so a value `.expense` paired with smaller `.expense` fee legs
      // resolves correctly. If two or more cash legs share the same
      // instrument, none of them is a fee — the transaction has
      // multiple value-bearing legs and is ineligible.
      if let valueLeg = Self.cashValueLeg(amongCashLegs: cashLegs) {
        return Self.valueLegIfFeesAreCrossInstrument(
          valueLeg: valueLeg,
          otherLegs: legs.filter { $0 != valueLeg })
      }
    }
    return nil
  }

  /// Selects the single value-bearing cash leg. Eligible cash shapes
  /// are: one `.income`/`.expense` leg by itself, or one such leg
  /// plus zero or more `.expense` fee legs in different instruments.
  /// When two or more legs sit in the same instrument the value-leg is
  /// ambiguous — caller treats the whole transaction as ineligible.
  private static func cashValueLeg(amongCashLegs cashLegs: [TransactionLeg]) -> TransactionLeg? {
    guard !cashLegs.isEmpty else { return nil }
    if cashLegs.count == 1 { return cashLegs[0] }
    // With ≥2 cash legs, the value leg is the unique-instrument one
    // (every other cash leg sits in its own distinct instrument and
    // is `.expense`-typed = a fee). If multiple cash legs share an
    // instrument the value leg is ambiguous.
    var byInstrument: [Instrument: [TransactionLeg]] = [:]
    for leg in cashLegs {
      byInstrument[leg.instrument, default: []].append(leg)
    }
    let dominant = byInstrument.values.filter { $0.count >= 2 }
    guard dominant.isEmpty else { return nil }
    // The value-bearing leg is the largest-magnitude cash leg; remaining
    // cash legs must be `.expense` fee legs in a different instrument
    // (validated by the cross-instrument predicate at the call site).
    let sorted = cashLegs.sorted { abs($0.quantity) > abs($1.quantity) }
    return sorted.first
  }

  /// Returns `valueLeg` when every other leg either is `.expense` and
  /// sits in a different instrument from `valueLeg` (a fee leg), or
  /// the leg list is empty. Returns `nil` otherwise — that shape isn't
  /// detection-eligible.
  private static func valueLegIfFeesAreCrossInstrument(
    valueLeg: TransactionLeg,
    otherLegs: [TransactionLeg]
  ) -> TransactionLeg? {
    let allFeeLegs = otherLegs.allSatisfy { leg in
      leg.type == .expense && leg.instrument != valueLeg.instrument
    }
    return allFeeLegs ? valueLeg : nil
  }
}
