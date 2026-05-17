import Foundation

/// Auto-merge / split validation failure.
///
/// Errors cross actor boundaries so they are explicitly `Sendable`;
/// cases carry no payload so it is trivially satisfied.
enum TransferMergeError: Error, Equatable, Sendable {
  case notMergeable  // detection-time / auto-merge precondition failed
  case notATransfer  // split() input is not a 2-transfer-leg tx
  case missingMergedOrigin  // split() input has no .merged importOrigin
  case mutationInProgress  // a merge/unmerge is already running (re-entrancy guard)
}
