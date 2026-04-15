import Foundation

/// A transaction leg paired with its amount converted to a target instrument.
/// `convertedAmount` is always populated — when the leg's instrument matches
/// the target, it equals `leg.amount`.
struct ConvertedTransactionLeg: Sendable {
  let leg: TransactionLeg
  let convertedAmount: InstrumentAmount
}
