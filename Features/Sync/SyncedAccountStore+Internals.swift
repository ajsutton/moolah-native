// Features/Sync/SyncedAccountStore+Internals.swift
import Foundation
import OSLog

/// Outcome of one per-account build task. The apply pass only consumes
/// `.success`; `.failed` accounts have their errors persisted inside the
/// build task itself, and `.skipped` accounts (cancelled, no matching
/// source) contribute nothing.
///
/// `.failed` carries the account's `AccountType` so `updateGlobalError`
/// can scope the Alchemy-key banner to crypto accounts — an exchange
/// credential failure must not light the (Alchemy-specific) global
/// banner.
enum PerAccountBuildResult: Sendable {
  case success(WalletApplyEngine.AccountInput)
  case failed(UUID, WalletSyncError, AccountType)
  case skipped(UUID)
}

extension SyncedAccountStore {

  // MARK: - Stale filter

  /// Filters `accounts.fetchAll()` down to syncable accounts (any
  /// account some registered `AccountSyncSource` claims) that are
  /// either stale (older than `staleThreshold`) or — when
  /// `includeNonStale == true` — every syncable account regardless.
  /// Reads `clock()` for "now" so tests can pin time.
  func accountsToSync(includeNonStale: Bool) async -> [Account] {
    let allAccounts: [Account]
    do {
      allAccounts = try await accounts.fetchAll()
    } catch {
      Self.internalsLogger.error(
        "Account fetch failed during stale check: \(error.localizedDescription, privacy: .public)"
      )
      return []
    }
    let now = clock()
    return allAccounts.filter { account in
      // `WalletSyncSource.handles` already enforces walletAddress +
      // chainId for crypto; exchange accounts have neither but are
      // claimed by `CoinstashSyncSource`. Asking the sources keeps the
      // stale-timer / scene-active path provider-neutral.
      guard source(for: account) != nil else { return false }
      if includeNonStale { return true }
      let lastSyncedAt = statePerAccount[account.id]?.lastSyncedAt ?? .distantPast
      return now.timeIntervalSince(lastSyncedAt) >= staleThreshold
    }
  }

  // MARK: - Parallel build

  /// Runs the parallel build phase for `accountList` via
  /// `withTaskGroup`, capping concurrency at `maxConcurrentBuilds`. A
  /// per-account failure is captured as a `lastError` write on
  /// `WalletSyncState` (preserving the prior `lastSyncedBlockNumber`)
  /// and contributes nothing to the apply phase. Native `WalletSyncError`
  /// values are stored as-is; unexpected `Error` types are wrapped in
  /// `.network(...)` so the persisted value stays inside the closed
  /// taxonomy `WalletSyncError` defines.
  ///
  /// Returns the full `PerAccountBuildResult` set (not just the
  /// successful inputs) so callers can scan failures for process-wide
  /// errors (`.missingApiKey` / `.invalidApiKey`) and surface them on
  /// `globalError`. The apply pass filters to `.success` itself.
  func runParallelBuilds(
    for accountList: [Account]
  ) async -> [PerAccountBuildResult] {
    let limit = maxConcurrentBuilds
    let sources = self.sources
    let walletSyncState = self.walletSyncState
    let statesById = self.statePerAccount

    return await withTaskGroup(
      of: PerAccountBuildResult.self,
      returning: [PerAccountBuildResult].self
    ) { group in
      var iterator = accountList.makeIterator()
      var dispatched = 0
      // Prime the group with the first `limit` tasks…
      while dispatched < limit, let account = iterator.next() {
        group.addTask {
          await Self.buildOne(
            account: account,
            sources: sources,
            walletSyncState: walletSyncState,
            priorState: statesById[account.id])
        }
        dispatched += 1
      }
      var collected: [PerAccountBuildResult] = []
      collected.reserveCapacity(accountList.count)
      // …then add a new task as each finishes so the group never holds
      // more than `limit` in-flight tasks at once.
      while let result = await group.next() {
        collected.append(result)
        if let next = iterator.next() {
          group.addTask {
            await Self.buildOne(
              account: next,
              sources: sources,
              walletSyncState: walletSyncState,
              priorState: statesById[next.id])
          }
        }
      }
      return collected
    }
  }

  /// One per-account build task. Static because `withTaskGroup` runs
  /// the body off `@MainActor` and a `nonisolated` static avoids
  /// capturing `self`. All dependencies are passed in.
  ///
  /// Cancellation propagates: a cancelled cycle never writes a
  /// half-resolved error row.
  nonisolated static func buildOne(
    account: Account,
    sources: [any AccountSyncSource],
    walletSyncState: any WalletSyncStateRepository,
    priorState: WalletSyncState?
  ) async -> PerAccountBuildResult {
    guard let source = sources.first(where: { $0.handles(account) }) else {
      internalsLogger.notice(
        "Skipping account \(account.id, privacy: .public) — no matching sync source"
      )
      return .skipped(account.id)
    }
    do {
      let built = try await source.build(account: account)
      // AccountInput construction is the same for crypto and exchange
      // accounts. For exchange accounts headBlockNumber is 0 (no block
      // watermark); for crypto the wallet engine fills it from fetched
      // transfers.
      let input = WalletApplyEngine.AccountInput(
        account: account,
        headBlockNumber: built.headBlockNumber,
        candidates: built.candidates)
      return .success(input)
    } catch is CancellationError {
      // Cooperative cancellation — never write a half-resolved row.
      return .skipped(account.id)
    } catch let walletError as WalletSyncError {
      await persistError(
        walletError,
        accountId: account.id,
        priorState: priorState,
        walletSyncState: walletSyncState)
      return .failed(account.id, walletError, account.type)
    } catch {
      let mapped = WalletSyncError.network(
        underlyingDescription: error.localizedDescription)
      await persistError(
        mapped,
        accountId: account.id,
        priorState: priorState,
        walletSyncState: walletSyncState)
      return .failed(account.id, mapped, account.type)
    }
  }

  /// Writes `lastError` onto the account's `WalletSyncState` while
  /// preserving the prior `lastSyncedBlockNumber` (so the next cycle's
  /// reorg-window math doesn't restart from genesis after a transient
  /// failure). On a fresh account with no prior state, writes a
  /// genesis-style row at block 0 so the `lastError` surfaces in the
  /// UI on the first failed attempt.
  ///
  /// `lastSyncedAt` is intentionally **not** updated on failure — the
  /// staleness check should still treat the account as overdue.
  nonisolated static func persistError(
    _ error: WalletSyncError,
    accountId: UUID,
    priorState: WalletSyncState?,
    walletSyncState: any WalletSyncStateRepository
  ) async {
    let state = WalletSyncState(
      id: accountId,
      lastSyncedBlockNumber: priorState?.lastSyncedBlockNumber ?? 0,
      lastSyncedAt: priorState?.lastSyncedAt ?? .distantPast,
      lastError: error)
    do {
      try await walletSyncState.save(state)
    } catch {
      internalsLogger.error(
        "Failed to persist sync error for account \(accountId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - Sequential apply

  /// Runs the sequential `@MainActor` apply pass over the build-phase
  /// outputs. A throwing apply pass is logged but does not surface to
  /// callers — per-account errors were already persisted in the build
  /// phase. `WalletApplyEngine` throws repository errors (GRDB /
  /// CloudKit), not `WalletSyncError`, so the global banner is driven
  /// entirely from the build-phase scan in `updateGlobalError(from:)`.
  func runApplyPass(
    perAccountResults: [PerAccountBuildResult]
  ) async {
    let inputs: [WalletApplyEngine.AccountInput] = perAccountResults.compactMap {
      if case let .success(input) = $0 { return input }
      return nil
    }
    do {
      _ = try await walletApplyEngine.apply(perAccount: inputs)
    } catch {
      Self.internalsLogger.warning(
        "WalletApplyEngine apply pass failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Updates `globalError` based on the build phase's per-account
  /// outcomes, **scoped to crypto accounts**. The banner powers
  /// `CryptoSettingsView.alchemyStatusBadge`, which is Alchemy-specific:
  /// the shared Alchemy key means an `.invalidApiKey` / `.missingApiKey`
  /// from any one *crypto* account implies no crypto account can sync,
  /// so we surface it once — preferring `.missingApiKey` over
  /// `.invalidApiKey` when both are present because the former gives
  /// the user a clearer instruction (add a key) than the latter
  /// (replace a key). An exchange account's per-account token failure
  /// (`.invalidApiKey` / `.missingApiKey` from `CoinstashSyncSource`)
  /// is deliberately ignored here — folding it in would tell the user
  /// the Alchemy key is broken when it is fine.
  ///
  /// When no crypto process-wide error appears in this cycle's outcomes
  /// the banner clears. Per-account errors (`.network`, `.rateLimited`,
  /// `.providerMalformedResponse`) are surfaced via the per-row
  /// `WalletSyncState.lastError`, not the banner.
  func updateGlobalError(from results: [PerAccountBuildResult]) {
    var sawMissing = false
    var sawInvalid = false
    for result in results {
      if case let .failed(_, error, accountType) = result, accountType == .crypto {
        switch error {
        case .missingApiKey:
          sawMissing = true
        case .invalidApiKey:
          sawInvalid = true
        default:
          break
        }
      }
    }
    if sawMissing {
      setGlobalError(.missingApiKey)
    } else if sawInvalid {
      setGlobalError(.invalidApiKey)
    } else {
      setGlobalError(nil)
    }
  }

  /// Re-loads `statePerAccount` from the repository so observable view
  /// state matches the persisted truth after the apply pass writes
  /// `lastSyncedBlockNumber` / `lastSyncedAt` (success) or `lastError`
  /// (failure). Errors here are non-fatal — the next launch reloads.
  func refreshStateFromRepository() async {
    await reloadStatePerAccount(failureLogPrefix: "WalletSyncState refresh")
  }

  // MARK: - Transfer detection

  /// Runs the cross-account fuzzy transfer-detection pass for the
  /// accounts that went through this sync cycle. Called once per
  /// `syncAccounts` pass, after the apply pass and the state refresh so
  /// the persisted rows are visible.
  ///
  /// The window lower bound is derived concretely from `clock()` and
  /// `FuzzyTransferDetector.windowSeconds` — not from `statePerAccount`,
  /// which reflects the post-apply checkpoint, not the imported window.
  /// `TransactionFilter` cannot express an account-set membership
  /// predicate, so the participating-account candidate set is filtered
  /// in-memory over the date-floored superset, mirroring the
  /// same-limitation in-memory approach
  /// `TransferDetectionCoordinator.runDetection` documents.
  ///
  /// The orchestration is intentionally thin: a single candidate fetch,
  /// an empty-set skip, and one `runDetection` call. All detection and
  /// merge logic lives in the coordinator / detector.
  ///
  /// The pre-check on `transferDetection.isMutating` exists so a
  /// background sync pass does not write `mutationInProgress` into the
  /// coordinator's user-visible `error` when the user is mid-merge /
  /// mid-dismiss or an overlapping detection pass is in flight; it also
  /// skips the candidate fetch in that case. The coordinator's `mutate`
  /// gate remains the final arbiter.
  func runTransferDetection(participatingAccountIds: Set<UUID>) async {
    guard !transferDetection.isMutating else {
      Self.internalsLogger.notice(
        "Transfer detection skipped — coordinator busy; the next sync pass covers this window")
      return
    }
    let windowLowerBound = clock().addingTimeInterval(
      -FuzzyTransferDetector.windowSeconds)
    let newlyImported: [Transaction]
    do {
      // The coordinator's `runDetection` independently re-fetches this
      // same date range for `existingNearby`. This second fetch here is
      // a deliberate trade-off: it enables the empty-participating-set
      // early-out and supplies `newlyImported` per the coordinator's
      // caller-supplies-`newlyImported` contract. The window is a
      // bounded 3 days over an in-memory GRDB store, so the duplicate
      // read is cheap — not an accidental double fetch.
      let candidates = try await transactions.fetchAll(
        filter: TransactionFilter(
          dateRange: windowLowerBound...Date.distantFuture))
      // `TransactionFilter` has no account-set field, so the
      // participating-account restriction is applied in-memory over the
      // date-floored superset.
      newlyImported = candidates.filter { transaction in
        guard let accountId = transaction.transferDetectionValueLeg?.accountId
        else { return false }
        return participatingAccountIds.contains(accountId)
      }
    } catch {
      Self.internalsLogger.error(
        "Transfer-detection candidate fetch failed: \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    guard !newlyImported.isEmpty else { return }
    await transferDetection.runDetection(
      newlyImported: newlyImported,
      participatingAccountIds: participatingAccountIds,
      windowLowerBound: windowLowerBound)
  }

  // MARK: - Timer

  /// Cancels any prior `timerTask` and starts a fresh one. Centralised
  /// so every entry point (scene-active, explicit re-arm) goes through
  /// the same cancel-then-spawn sequence.
  func restartTimer() {
    cancelTimer()
    timerTask = Task { [weak self] in
      await self?.runTimerLoop()
    }
  }

  /// Hourly stale-check loop. Foreground only — entry/exit is gated by
  /// `handleScenePhaseChange`. `Task.sleep` itself throws on cancellation;
  /// the explicit `Task.checkCancellation()` between sleep and dispatch
  /// catches a late cancellation that arrives in the gap so a cancelled
  /// task exits without leaking a fetch.
  func runTimerLoop() async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: timerInterval)
        try Task.checkCancellation()
      } catch {
        return
      }
      await syncStaleAccounts()
    }
  }

  /// Logger for internals-extension diagnostics. Static and `Sendable`
  /// so the cross-actor `buildOne` / `persistError` helpers can call
  /// it without capturing `self`.
  nonisolated private static let internalsLogger = Logger(
    subsystem: "com.moolah.app", category: "SyncedAccountStore")
}
