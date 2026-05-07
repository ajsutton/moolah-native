import Foundation

// CloudKit-sync reload debouncing, sync teardown, and the
// `updateProfile` mutator. Extracted from `ProfileSession.swift` so
// the main file stays under SwiftLint's `file_length` threshold.
// Reaches the session's module-internal sync state
// (`syncReloadTask`, `pendingChangedTypes`, `lastSyncEventTime`,
// `syncObserverToken`, `catalogRefreshTask`, `crossStoreUpdateTasks`,
// `setUpTask`) — those properties are deliberately module-internal in
// `ProfileSession.swift` so this file can manage their lifecycle.

extension ProfileSession {
  // MARK: - CloudKit Sync

  /// Debounces sync reloads — cancels any pending reload and waits briefly.
  /// This avoids redundant reloads when CKSyncEngine delivers multiple change batches
  /// in quick succession. Only reloads stores affected by the changed record types.
  /// During bulk sync (rapid consecutive batches), the debounce increases to 2s to
  /// avoid thrashing.
  ///
  /// `internal` (not `private`) because Swift's `private` does not cross
  /// file boundaries. The sole caller is the closure in
  /// `registerWithSyncCoordinator` in `ProfileSession.swift`.
  func scheduleReloadFromSync(changedTypes: Set<String>) {
    pendingChangedTypes.formUnion(changedTypes)

    let now = ContinuousClock.now
    let isBulkSync: Bool
    if let last = lastSyncEventTime, now - last < .seconds(1) {
      isBulkSync = true
    } else {
      isBulkSync = false
    }
    lastSyncEventTime = now
    let debounceMs = isBulkSync ? 2000 : 500

    syncReloadTask?.cancel()
    syncReloadTask = Task {
      // CancellationError from Task.sleep is intentional — the guard below handles it.
      try? await Task.sleep(for: .milliseconds(debounceMs))
      guard !Task.isCancelled else { return }

      let types = self.pendingChangedTypes
      self.pendingChangedTypes.removeAll()

      let reloadStart = ContinuousClock.now
      logger.debug("Reloading stores after CloudKit sync: \(types)")
      // Every store is reactive (subscribes to its repository's
      // `observeAll()` in `init`); remote writes propagate without an
      // explicit reload here. `Self.storesToReload(for:)` is retained
      // and unit-tested so a future imperative store can be re-added
      // to the plan without resurrecting the dispatch site.
      let reloadMs = (ContinuousClock.now - reloadStart).inMilliseconds
      logger.info("📊 Store reloads after sync completed in \(reloadMs)ms for types: \(types)")
    }
  }

  // MARK: - Sync Cleanup

  /// Removes the sync observer from the coordinator (when one exists) and
  /// cancels every tracked task owned by the session. Coordinator-related
  /// work is gated on `coordinator != nil`; task cancellation runs
  /// unconditionally so nil-coordinator builds (preview / some tests) do
  /// not leak `syncReloadTask`, `setUpTask`, etc. past teardown.
  func cleanupSync(coordinator: SyncCoordinator?) {
    if let coordinator {
      if let token = syncObserverToken {
        coordinator.removeObserver(token: token)
      }
      coordinator.removeInstrumentRemoteChangeCallback(profileId: profile.id)
    }
    syncObserverToken = nil
    syncReloadTask?.cancel()
    syncReloadTask = nil
    catalogRefreshTask?.cancel()
    catalogRefreshTask = nil
    cryptoSyncStore?.cancelTimer()
    pragmaOptimizeTask?.cancel()
    pragmaOptimizeTask = nil
    periodicPragmaOptimizeTask?.cancel()
    periodicPragmaOptimizeTask = nil
    for task in crossStoreUpdateTasks {
      task.cancel()
    }
    crossStoreUpdateTasks.removeAll()
    setUpTask?.cancel()
    setUpTask = nil

    // Tear down reactive observation. MUST run AFTER any GRDB wipes so
    // the empty-state transition reaches subscribed views before the
    // task is cancelled. See `signOutTeardownOrdering` tests across the
    // per-store sync-refresh test suites.
    accountStore.stopObserving()
    earmarkStore.stopObserving()
    categoryStore.stopObserving()
    importRuleStore.stopObserving()
    transactionStore.stopObserving()
  }

  // MARK: - Profile Update

  /// Replaces `self.profile` with an updated copy. Used by the
  /// `SessionManager` bump-on-write path to keep the in-memory value
  /// consistent with what was just persisted to `profile-index.sqlite`.
  /// Identity must not change — the session is keyed on `profile.id`
  /// in `SessionManager.sessions`; an identity swap would orphan the
  /// dictionary entry.
  func updateProfile(_ updated: Profile) {
    precondition(
      updated.id == profile.id,
      "updateProfile must not change identity; the session is keyed on profile.id")
    self.profile = updated
  }
}
