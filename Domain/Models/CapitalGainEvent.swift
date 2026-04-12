import Foundation

/// A realized capital gain or loss from selling (part of) a lot.
struct CapitalGainEvent: Sendable, Hashable {
  let instrument: Instrument
  let sellDate: Date
  let acquiredDate: Date
  let quantity: Decimal
  let costBasis: Decimal
  let proceeds: Decimal
  let holdingDays: Int

  /// Gain or loss. Positive = gain, negative = loss.
  var gain: Decimal { proceeds - costBasis }

  /// Australian CGT: assets held > 12 months qualify for 50% discount.
  var isLongTerm: Bool { holdingDays > 365 }
}
