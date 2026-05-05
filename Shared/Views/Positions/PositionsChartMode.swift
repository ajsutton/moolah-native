import Foundation

/// Distinguishes the aggregate (account-wide) chart from the
/// per-instrument chart. Each mode uses a different baseline:
/// `contributions` for aggregate (cumulative net cash flows from
/// other accounts), `cost` for per-instrument (remaining FIFO cost
/// basis of currently held lots).
enum PositionsChartMode: Sendable {
  case aggregate
  case perInstrument
}
