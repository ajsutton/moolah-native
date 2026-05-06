import Foundation

protocol TransactionRepository: Sendable {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage
  /// Returns every matching transaction without pagination. Used by bulk
  /// consumers (profile export, profile import) where paginating forces the
  /// backend to re-filter and re-sort the whole dataset per page. Skips the
  /// prior-balance computation since it is not meaningful for the bulk path.
  func fetchAll(filter: TransactionFilter) async throws -> [Transaction]
  func create(_ transaction: Transaction) async throws -> Transaction
  func update(_ transaction: Transaction) async throws -> Transaction
  func delete(id: UUID) async throws
  /// Frequency-sorted payee strings beginning with `prefix`. When
  /// `excludingTransactionId` is supplied, the matching transaction does
  /// not contribute to the frequency count and its payee will not appear
  /// in the result if no other transaction shares it. Unknown ids — and
  /// unsaved drafts — leave the unfiltered list intact.
  func fetchPayeeSuggestions(prefix: String, excludingTransactionId: UUID?) async throws
    -> [String]
  /// Returns every persisted leg whose `external_id` equals `externalId`.
  /// Used by the wallet importer's cross-account merge pass to pair an
  /// in-batch candidate against legs already persisted on a prior cycle
  /// (so the same on-chain hash arriving via two accounts on different
  /// devices still merges into one transaction).
  ///
  /// Domain return type — the leg's instrument is resolved during the
  /// fetch the same way `fetch(filter:…)` and `fetchAll(filter:)` resolve
  /// it. The schema's partial unique index on
  /// `(account_id, external_id)` keeps this lookup cheap.
  func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg]
  /// Returns every transaction that has at least one leg whose
  /// `external_id` matches any value in `externalIds`, with full leg
  /// payloads loaded. Used by `CrossDeviceLegDeduper` to scope its post-
  /// CKSyncEngine sweep to transactions that the just-applied fetch could
  /// have touched — the deduper needs each leg's parent `Transaction.id`
  /// to know which row to route through `delete(id:)`. Empty input
  /// returns an empty result without hitting the database. The schema's
  /// partial unique index `leg_dedup_by_account_external` covers the
  /// underlying leg-side `IN` predicate, so even thousand-id sweeps stay
  /// cheap.
  func transactions(touchingExternalIds externalIds: Set<String>) async throws
    -> [Transaction]
  /// `true` iff the wallet importer has already persisted a leg keyed by
  /// `(accountId, externalId)`. Used by the per-leg dedup step of the
  /// apply pass — re-fetches that span the reorg window cover already-
  /// imported transactions, so each leg is checked against the partial
  /// unique index before insertion.
  func legExists(accountId: UUID, externalId: String) async throws -> Bool
}

extension TransactionRepository {
  /// Convenience overload with `excludingTransactionId` defaulting to
  /// `nil`. Returns the unfiltered frequency-sorted prefix matches.
  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    try await fetchPayeeSuggestions(prefix: prefix, excludingTransactionId: nil)
  }
}
