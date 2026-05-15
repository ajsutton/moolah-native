import Foundation

// Reactive observation pipeline for `EarmarkStore`. Lives in an
// extension so the main type body stays under SwiftLint's
// `type_body_length` and `file_length` budgets. `observe()` owns the
// always-on streams (`repository.observeAll()` +
// `conversionService.observeRates()`); the shared-registry change
// stream is owned by `instrumentChangeObservationTask` and drained by
// `observeInstrumentRegistryChanges` below (see the property docs on
// `EarmarkStore` for why each surface exists).
extension EarmarkStore {

  /// Subscribes to the four reactive streams in parallel via a
  /// `TaskGroup`. The child tasks run nonisolated; each per-emission
  /// body awaits a `@MainActor`-isolated method on `self` so state
  /// assignments happen on the main actor. Capturing the streams
  /// locally (instead of `self.repository.observeAll()` inside the
  /// `addTask` closure) lets the region-based isolation checker reason
  /// about Sendable-ness.
  func observe() async {
    let earmarksStream = repository.observeAll()
    let earmarkErrors = repository.observeErrors()
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in earmarksStream {
          await self.apply(earmarks: fresh)
        }
      }
      group.addTask { [self] in
        for await error in earmarkErrors {
          await self.surface(error: error)
        }
      }
      group.addTask { [self] in
        for await _ in rateStream {
          await self.recomputeConvertedTotals()
        }
      }
      group.addTask { [self] in
        for await error in rateErrors {
          await self.surface(error: error)
        }
      }
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// Consumes the shared instrument registry's change stream. Each tick
  /// re-fetches the earmarks list and re-applies it so an instrument-
  /// metadata edit applied to the shared registry (which does not
  /// re-fire `repository.observeAll()`) live-refreshes an open earmark
  /// list. `Task.isCancelled` is re-checked after the stream suspension
  /// so a teardown that races a tick exits before issuing a fetch. The
  /// task's lifetime is gated by `stopObserving()` / `deinit`, matching
  /// `observe()`.
  func observeInstrumentRegistryChanges(_ changes: AsyncStream<Void>) async {
    for await _ in changes {
      if Task.isCancelled { return }
      do {
        let fresh = try await repository.fetchAll()
        if Task.isCancelled { return }
        await apply(earmarks: fresh)
      } catch {
        surface(error: error)
      }
    }
  }
}
