import Foundation

// Reactive observation pipeline for `InvestmentStore`. Lives in an
// extension so the main type body stays under SwiftLint's
// `type_body_length` and `file_length` budgets.
//
// Two observation surfaces participate:
//   1. Always-on streams subscribed in `init`: `repository.observeErrors()`,
//      `conversionService.observeRates()`, `conversionService.observeErrors()`.
//      `runAlwaysOnObservation()` drives them via a `TaskGroup` owned by
//      `observationTask`.
//   2. Per-account streams subscribed in `setActiveAccount(...)`:
//      `repository.observeValues(accountId:page:pageSize:)`. The task
//      handle lives on `perAccountObservationTask` and is cancelled
//      whenever the active accountId changes.
//
// The store does NOT subscribe to `repository.observeDailyBalances(...)`
// reactively because the `dailyBalances` projection requires
// host-currency aggregation via `conversionService` (see
// `aggregateDailyBalances`); that step is async and runs on the
// consumer's actor. The rate-tick handler re-runs `loadDailyBalances`
// when rates change, and `loadAllData` runs it on the initial load.
extension InvestmentStore {

  /// Subscribes to the always-on reactive streams. Per-account streams
  /// are owned by `perAccountObservationTask` and (re)spawned by
  /// `setActiveAccount(...)`.
  func runAlwaysOnObservation() async {
    let repoErrors = repository.observeErrors()
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await error in repoErrors { await self.surfaceObservationError(error) }
      }
      group.addTask { [self] in
        for await _ in rateStream { await self.recomputeOnRateTick() }
      }
      group.addTask { [self] in
        for await error in rateErrors { await self.surfaceObservationError(error) }
      }
    }
  }

  /// Switches the active account context to `accountId`, replacing any
  /// prior per-account subscription. Subscribes to
  /// `repository.observeValues(...)` which drives the `values` array.
  ///
  /// Idempotent: a no-op when called with the currently-active id and
  /// the existing task is alive. Pass `nil` to clear the active context
  /// (used by tear-down paths and the trades-mode branch of
  /// `loadAllData`).
  func setActiveAccount(_ accountId: UUID?) {
    if loadedAccountId == accountId, perAccountObservationTask?.isCancelled == false {
      return
    }
    perAccountObservationTask?.cancel()
    setLoadedAccountId(accountId)
    guard let accountId else {
      setValues([])
      return
    }
    let valuesStream = repository.observeValues(
      accountId: accountId, page: 0, pageSize: pagedValuesPageSize)
    perAccountObservationTask = Task { [self] in
      for await page in valuesStream {
        await self.applyValuesPage(page, accountId: accountId)
      }
    }
  }

  /// Applies a fresh values page to the store. Wrapped in the Layer 7
  /// signpost so benchmarks and Instruments traces can attribute
  /// `mainThreadMs` to this method.
  func applyValuesPage(_ page: InvestmentValuePage, accountId: UUID) async {
    guard loadedAccountId == accountId else { return }
    await withReactiveStoreSignpost("investment-store-apply") {
      setValues(page.values)
      // Recompute the legacy performance from the new values + the
      // existing dailyBalances (set by `loadDailyBalances`).
      refreshLegacyPerformance()
      yieldTestObservationTick()
    }
  }

  /// Drives the rate-tick recompute. Re-runs the legacy daily-balance
  /// aggregation (which is conversion-sensitive) and the position
  /// valuations against the active account, if any. The values stream
  /// is conversion-free and is driven by the per-account observation,
  /// so we don't touch `values` here.
  func recomputeOnRateTick() async {
    guard let accountId = loadedAccountId, let host = loadedHostCurrency else { return }
    await loadDailyBalances(accountId: accountId, hostCurrency: host)
    if !positions.isEmpty {
      await valuatePositions(profileCurrency: host, on: Date())
    }
    refreshLegacyPerformance()
    yieldTestObservationTick()
  }

  /// Surface an observation error onto `self.error`. internal so the
  /// observation child tasks can call into MainActor-isolated state.
  func surfaceObservationError(_ error: any Error) {
    logger.error("InvestmentStore observation error: \(error.localizedDescription)")
    setError(error)
  }
}
