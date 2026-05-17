import Foundation

// Transfer-suggestion orchestration for the transaction-detail surface.
//
// A suggested transfer carries only the counterpart's id
// (`TransferSuggestion.counterpartTransactionId`); the detail surface
// has no loaded transaction set to look the counterpart up in. These
// methods resolve the counterpart through the repository and delegate
// the actual collapse / dismissal to `TransferDetectionCoordinator`, so
// the suggestion section stays a thin renderer dispatching one-line
// `Task { await transactionStore.mergeSuggestedTransfer(...) }` calls.
extension TransactionStore {

  /// Collapses the suggested pair into one merged two-leg transfer.
  /// Resolves `transaction.transferSuggestion?.counterpartTransactionId`
  /// to its `Transaction` and hands both sides to the coordinator. A
  /// no-op when the store has no coordinator wired, the transaction
  /// carries no suggestion, or the counterpart row can no longer be
  /// found. The coordinator surfaces any failure on its own `error`
  /// channel.
  func mergeSuggestedTransfer(_ transaction: Transaction) async {
    guard let coordinator = transferDetection else { return }
    do {
      guard let counterpart = try await suggestedCounterpart(of: transaction)
      else { return }
      await coordinator.merge(transaction, counterpart)
    } catch {
      logger.error(
        "Failed to resolve transfer counterpart: \(error.localizedDescription)")
      setError(error)
    }
  }

  /// Records a "not a transfer" dismissal over the suggested pair and
  /// clears the suggestion annotation on both sides. Same guards and
  /// no-op semantics as `mergeSuggestedTransfer(_:)`.
  func dismissSuggestedTransfer(_ transaction: Transaction) async {
    guard let coordinator = transferDetection else { return }
    do {
      guard let counterpart = try await suggestedCounterpart(of: transaction)
      else { return }
      await coordinator.dismiss(transaction, counterpart)
    } catch {
      logger.error(
        "Failed to resolve transfer counterpart: \(error.localizedDescription)")
      setError(error)
    }
  }

  /// Loads the counterpart `Transaction` named by the transaction's
  /// transfer suggestion. The repository exposes no fetch-by-id, so this
  /// scans the unfiltered projection and matches on id — acceptable
  /// because merge / dismiss are deliberate, infrequent user actions on
  /// the detail surface, not a hot path. Returns `nil` when the
  /// transaction carries no suggestion or the counterpart row is gone
  /// (already merged / deleted on another device).
  private func suggestedCounterpart(
    of transaction: Transaction
  ) async throws -> Transaction? {
    guard let counterpartId = transaction.transferSuggestion?.counterpartTransactionId
    else { return nil }
    let all = try await repository.fetchAll(filter: TransactionFilter())
    return all.first { $0.id == counterpartId }
  }
}
