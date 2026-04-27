import Foundation
import OSLog

extension TransactionStore {
  /// Emits the per-step `fetchPage` timing breakdown at `.info` for non-trivial
  /// fetches, falling back to a one-line `.debug` summary otherwise. Lives in
  /// an extension so the timing instrumentation doesn't push the main store
  /// body over its SwiftLint length budget; the caller passes its `logger`
  /// rather than this file widening the access modifier on the property. See
  /// `plans/2026-04-27-upcoming-card-cold-load-plan.md`.
  static func logFetchPageTiming(
    logger: Logger, fetchMs: Int, recomputeMs: Int, count: Int, totalLoaded: Int
  ) {
    if fetchMs + recomputeMs > 100 {
      logger.info(
        """
        fetchPage took \(fetchMs + recomputeMs)ms (repo.fetch: \(fetchMs)ms, \
        recomputeBalances: \(recomputeMs)ms, count: \(count))
        """)
    } else {
      logger.debug("Loaded \(count) transactions (total: \(totalLoaded))")
    }
  }
}
