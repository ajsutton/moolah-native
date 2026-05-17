import Foundation

/// Annotation on both sides of a detected fuzzy transfer pair, pointing
/// at the counterpart transaction. Cleared by merge or dismiss. Synced
/// via the transaction record's denormalised columns.
struct TransferSuggestion: Codable, Sendable, Hashable {
  let counterpartTransactionId: UUID
  let suggestedAt: Date
}
