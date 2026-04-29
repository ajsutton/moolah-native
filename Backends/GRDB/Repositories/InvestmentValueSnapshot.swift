import Foundation

/// One investment value snapshot: an amount recorded for an account
/// on a specific date. Used by `GRDBAnalysisRepository` to pass
/// investment positions between the SQL fetch and the per-day fold-in
/// without a 3-member tuple.
struct InvestmentValueSnapshot: Sendable {
  let accountId: UUID
  let date: Date
  let value: InstrumentAmount
}
