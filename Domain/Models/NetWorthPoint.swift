import Foundation

/// A single point in a net worth time series, with all positions converted to profile currency.
struct NetWorthPoint: Sendable, Hashable {
  let date: Date
  let value: InstrumentAmount  // Always in profile currency
}
