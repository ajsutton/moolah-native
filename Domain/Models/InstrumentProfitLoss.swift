import Foundation

/// Per-instrument profit and loss summary.
struct InstrumentProfitLoss: Sendable, Identifiable, Hashable {
  var id: String { instrument.id }

  let instrument: Instrument
  let currentQuantity: Decimal
  let totalInvested: Decimal
  let currentValue: Decimal
  let realizedGain: Decimal
  let unrealizedGain: Decimal

  /// Total return = realized + unrealized
  var totalGain: Decimal { realizedGain + unrealizedGain }

  /// Return percentage on total invested
  var returnPercentage: Decimal {
    guard totalInvested != 0 else { return 0 }
    return (totalGain / totalInvested) * 100
  }
}
