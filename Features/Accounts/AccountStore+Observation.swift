import Foundation

// Reactive observation pipeline for `AccountStore`. Lives in an
// extension so the main type body stays under SwiftLint's
// `type_body_length` and `file_length` budgets.
//
// Three independent surfaces feed `AccountStore`:
//   1. `repository.observeAll()` / `observeErrors()` — the accounts
//      stream that drives `apply(accounts:)`.
//   2. `conversionService.observeRates()` / `observeErrors()` — rate
//      ticks that drive a balance recompute (no DB re-fetch needed).
//   3. `investmentRepository.observeAllValues()` / `observeErrors()` —
//      a tick stream over the `investment_value` table that drives a
//      cache refresh + recompute. Replaces the cross-store
//      `onInvestmentValueChanged` callback that previously lived on
//      `InvestmentStore`.
//
// All `addTask` bodies are deliberately one-line so the enclosing
// closure body stays under SwiftLint's `closure_body_length`.
extension AccountStore {

  /// Subscribes to every reactive stream in parallel via a `TaskGroup`.
  /// The child tasks run nonisolated; each per-emission body awaits a
  /// `@MainActor`-isolated method on `self` so state assignments happen
  /// on the main actor. Capturing the streams locally (instead of
  /// `self.repository.observeAll()` inside the `addTask` closure) lets
  /// the region-based isolation checker reason about Sendable-ness.
  func observe() async {
    let accountsStream = repository.observeAll()
    let accountErrors = repository.observeErrors()
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    let investmentValuesTick = investmentRepository?.observeAllValues()
    let investmentErrors = investmentRepository?.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      addCoreObservationTasks(
        to: &group,
        accountsStream: accountsStream,
        accountErrors: accountErrors,
        rateStream: rateStream,
        rateErrors: rateErrors)
      addInvestmentObservationTasks(
        to: &group,
        valuesTick: investmentValuesTick,
        errors: investmentErrors)
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// Wires the four always-on subscriptions into `group`. Pulled out so
  /// the `observe()` body fits inside SwiftLint's closure body length.
  private func addCoreObservationTasks(
    to group: inout TaskGroup<Void>,
    accountsStream: AsyncStream<[Account]>,
    accountErrors: AsyncStream<any Error>,
    rateStream: AsyncStream<Void>,
    rateErrors: AsyncStream<any Error>
  ) {
    group.addTask { [self] in
      for await fresh in accountsStream { await self.applyAccountsSnapshot(fresh) }
    }
    group.addTask { [self] in
      for await error in accountErrors { await self.surfaceObservationError(error) }
    }
    group.addTask { [self] in
      for await _ in rateStream { await self.recomputeForRateTick() }
    }
    group.addTask { [self] in
      for await error in rateErrors { await self.surfaceObservationError(error) }
    }
  }

  /// Wires the optional investment-repository subscriptions into `group`.
  /// `nil` streams (no investment repository configured — preview /
  /// degraded launches) are simply skipped.
  private func addInvestmentObservationTasks(
    to group: inout TaskGroup<Void>,
    valuesTick: AsyncStream<Void>?,
    errors: AsyncStream<any Error>?
  ) {
    if let valuesTick {
      group.addTask { [self] in
        for await _ in valuesTick { await self.refreshInvestmentValuesAndRecompute() }
      }
    }
    if let errors {
      group.addTask { [self] in
        for await error in errors { await self.surfaceObservationError(error) }
      }
    }
  }
}
