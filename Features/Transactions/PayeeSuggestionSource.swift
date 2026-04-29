import Foundation
import OSLog
import Observation

/// Debounced autocomplete source for payee input. Owns a single in-flight
/// fetch task so consecutive keystrokes cancel pending queries instead of
/// racing them. Extracted from `TransactionStore` because the concern is
/// input-field autocomplete — distinct from transaction CRUD — with its own
/// state (`suggestions`) and lifecycle (debounce task).
///
/// `@Observable` so views can bind to `suggestions` through
/// `TransactionStore`'s forwarding property; Observation's transitive
/// tracking picks up changes here even when the view holds only a
/// `TransactionStore` reference.
@Observable
@MainActor
final class PayeeSuggestionSource {
  private(set) var suggestions: [String] = []

  private let repository: TransactionRepository
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "PayeeSuggestionSource")
  private var task: Task<Void, Never>?

  init(repository: TransactionRepository) {
    self.repository = repository
  }

  /// Debounces (200 ms), then fetches suggestions matching `prefix`. An
  /// empty prefix clears the current list without issuing a request.
  /// Subsequent calls cancel any pending fetch so only the most recent
  /// keystroke's request completes.
  ///
  /// `excludingTransactionId` is the id of the transaction the user is
  /// editing; the repo drops it from the frequency count so a row never
  /// suggests its own payee back to itself (#538). Pass `nil` for
  /// non-editing contexts.
  func fetch(prefix: String, excludingTransactionId: UUID? = nil) {
    task?.cancel()

    guard !prefix.isEmpty else {
      suggestions = []
      return
    }

    task = Task {
      try? await Task.sleep(nanoseconds: 200_000_000)
      guard !Task.isCancelled else { return }

      do {
        let results = try await repository.fetchPayeeSuggestions(
          prefix: prefix, excludingTransactionId: excludingTransactionId)
        guard !Task.isCancelled else { return }
        suggestions = results
      } catch {
        guard !Task.isCancelled else { return }
        logger.error("Failed to fetch payee suggestions: \(error.localizedDescription)")
        suggestions = []
      }
    }
  }

  /// Cancels any pending fetch and empties the current list.
  func clear() {
    task?.cancel()
    suggestions = []
  }

  /// Fetches the most recent transaction matching `payee`, used by the
  /// payee-autocomplete UI to pre-fill the rest of a draft transaction with
  /// values from the prior occurrence. Bypasses the suggestion-list debounce
  /// because callers invoke it after the user has explicitly chosen a payee.
  func fetchTransactionForAutofill(payee: String) async -> Transaction? {
    do {
      let page = try await repository.fetch(
        filter: TransactionFilter(payee: payee), page: 0, pageSize: 1)
      return page.transactions.first
    } catch {
      logger.error("Failed to fetch autofill transaction: \(error.localizedDescription)")
      return nil
    }
  }
}
