import Foundation

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

  /// Capital-gains values in a form suitable for populating
  /// `TaxYearAdjustments` fields. Nested because it is only ever produced
  /// by `asTaxAdjustmentValues(currency:)` below.
  struct TaxAdjustmentValues {
    /// Gains from assets held < 12 months.
    let shortTerm: InstrumentAmount
    /// Pre-discount gains from assets held > 12 months.
    let longTerm: InstrumentAmount
    /// Magnitude of net losses, expressed as a non-negative quantity for the
    /// "Capital losses" `TaxYearAdjustments` field. Built from the negative
    /// portions of `shortTermGain` / `longTermGain` via unary minus, so the
    /// monetary sign is preserved through the flip rather than discarded
    /// with `abs()`.
    let losses: InstrumentAmount
  }
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
    // `totalLoss` sums the negative portions only, so it's always ≤ 0.
    // Flip with unary minus to populate the `losses` field as a non-negative
    // magnitude — never use `abs()` on a monetary quantity.
    let totalLoss = min(0, shortTermGain) + min(0, longTermGain)
    let losses = InstrumentAmount(
      quantity: -totalLoss, instrument: currency
    )
    return TaxAdjustmentValues(shortTerm: shortTerm, longTerm: longTerm, losses: losses)
  }
}
