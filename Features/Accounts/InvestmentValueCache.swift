import Foundation
import OSLog

/// Caches the latest externally-set value for each investment account and
/// knows how to hydrate itself from the investment repository.
///
/// Investment accounts can have a user-supplied "current value" that's more
/// authoritative than the transaction position sum (e.g. a mark-to-market
/// share price). This cache holds those values so `AccountStore` can:
///   - preload them on `load()` so the sidebar doesn't flash the position
///     sum before the user touches an account,
///   - accept callbacks from `InvestmentStore` when the user sets/clears a
///     value, so aggregate totals stay in sync without a round-trip.
///
/// The cache is not `@Observable`: the observable surface is `AccountStore`'s
/// `convertedBalances` / `convertedInvestmentTotal`, which the store
/// recomputes whenever cache contents change.
/// `Logger` is `Sendable`; declared at file scope so the per-account
/// `withTaskGroup` body (a non-isolated context) can warn on fetch
/// failures without a MainActor hop.
private let preloadLogger = Logger(
  subsystem: "com.moolah.app", category: "InvestmentValueCache")

@MainActor
final class InvestmentValueCache {
  /// The current cache contents. Kept `private(set)` so callers can read for
  /// diagnostics / tests, but mutation goes through `set(_:for:)` / `preload`.
  private(set) var values: [UUID: InstrumentAmount] = [:]

  private let repository: (any InvestmentRepository)?

  init(repository: (any InvestmentRepository)? = nil) {
    self.repository = repository
  }

  func value(for accountId: UUID) -> InstrumentAmount? {
    values[accountId]
  }

  /// Sets or clears the cached value for `accountId`. Pass `nil` to remove.
  func set(_ value: InstrumentAmount?, for accountId: UUID) {
    if let value {
      values[accountId] = value
    } else {
      values.removeValue(forKey: accountId)
    }
  }

  /// Fetches the latest value for each given account ID in parallel and
  /// stores successful results. Per-account failures are silently tolerated
  /// — absence means the cached value is unknown. For `recordedValue`
  /// accounts `displayBalance` returns zero when absent; for
  /// `calculatedFromTrades` accounts it sums positions. A single account's
  /// fetch failure never blocks the rest of the load.
  func preload(for accountIds: [UUID]) async {
    guard let repository, !accountIds.isEmpty else { return }

    let repo = repository
    let results = await withTaskGroup(
      of: (UUID, InstrumentAmount?).self,
      returning: [(UUID, InstrumentAmount?)].self
    ) { group in
      for accountId in accountIds {
        group.addTask {
          do {
            let page = try await repo.fetchValues(
              accountId: accountId, page: 0, pageSize: 1)
            return (accountId, page.values.first?.value)
          } catch {
            // nil-fallback is the intended degradation (callers fall back
            // to position sum), but the failure must be logged so prod
            // diagnostics can distinguish "no value set" from "fetch
            // raised an error". Per INSTRUMENT_CONVERSION_GUIDE.md Rule 11.
            preloadLogger.warning(
              "preload: fetch failed for \(accountId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return (accountId, nil)
          }
        }
      }
      var collected: [(UUID, InstrumentAmount?)] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    for (accountId, value) in results {
      if let value {
        values[accountId] = value
      }
    }
  }
}
