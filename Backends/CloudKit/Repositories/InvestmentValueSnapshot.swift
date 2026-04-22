import Foundation

/// One investment value snapshot: an amount recorded for an account on a
/// specific date. Used by `CloudKitAnalysisRepository` to pass investment
/// positions between its SwiftData fetch and its off-main computations
/// without a 3-member tuple.
struct InvestmentValueSnapshot: Sendable {
  let accountId: UUID
  let date: Date
  let value: InstrumentAmount

  /// Bridges a SwiftData record into a Sendable snapshot. Provided so the
  /// call site in `CloudKitAnalysisRepository` can pass
  /// `InvestmentValueSnapshot.init(record:)` straight to `Array.map`.
  init(record: InvestmentValueRecord) {
    self.accountId = record.accountId
    self.date = record.date
    self.value = record.toDomain().value
  }
}
