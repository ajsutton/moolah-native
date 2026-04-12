import Foundation

/// A lot (tax parcel) of an instrument acquired at a specific cost on a specific date.
/// Used by the FIFO cost basis engine to track open positions.
struct CostBasisLot: Sendable, Hashable, Identifiable {
  let id: UUID
  let instrument: Instrument
  let acquiredDate: Date
  let costPerUnit: Decimal
  let originalQuantity: Decimal
  var remainingQuantity: Decimal

  var totalCost: Decimal { originalQuantity * costPerUnit }
  var remainingCost: Decimal { remainingQuantity * costPerUnit }
}
