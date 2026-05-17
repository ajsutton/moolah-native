import Foundation

/// Manual-merge validation failure (looser ±14-day window; user asserts intent).
enum ManualMergeError: Error, Equatable, Sendable {
  case sameAccount
  case notOppositeAmount  // value legs not opposite-equal / instrument mismatch
  case datesTooFarApart  // > manualMergeWindowSeconds
}
