import Foundation

/// One detected fuzzy candidate pair. Ordered: `newlyImported` is the
/// just-imported transaction; `existingCounterpart` is the match it
/// pairs with (which may itself be in the newly-imported set).
struct TransferCandidatePair: Sendable, Hashable {
  let newlyImported: Transaction
  let existingCounterpart: Transaction
}
