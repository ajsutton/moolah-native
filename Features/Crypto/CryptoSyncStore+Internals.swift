// Features/Crypto/CryptoSyncStore+Internals.swift
import Foundation
import OSLog
import SwiftUI

/// Outcome of one per-account build task. Stage 9's apply pass only
/// consumes `.success`; `.failed` accounts have their errors persisted
/// inside the build task itself, and `.skipped` accounts (cancelled,
/// unknown chain id) contribute nothing.
enum PerAccountBuildResult: Sendable {
  case success(WalletApplyEngine.AccountInput)
  case failed(UUID, WalletSyncError)
  case skipped(UUID)
}

extension CryptoSyncStore {

  // MARK: - Stale filter

  /// Filters `accounts.fetchAll()` down to crypto accounts that are
  /// either stale (older than `staleThreshold`) or — when
  /// `includeNonStale == true` — every crypto account regardless. Reads
  /// `clock()` for "now" so tests can pin time.
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
      guard account.type == .crypto else { return false }
      guard account.walletAddress?.isEmpty == false else { return false }
      guard account.chainId != nil else { return false }
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
  func runParallelBuilds(
    for accountList: [Account]
  ) async -> [WalletApplyEngine.AccountInput] {
    let limit = maxConcurrentBuilds
    let walletSyncEngine = self.walletSyncEngine
    let walletSyncState = self.walletSyncState
    let statesById = self.statePerAccount

    return await withTaskGroup(
      of: PerAccountBuildResult.self,
      returning: [WalletApplyEngine.AccountInput].self
    ) { group in
      var iterator = accountList.makeIterator()
      var dispatched = 0
      // Prime the group with the first `limit` tasks…
      while dispatched < limit, let account = iterator.next() {
        group.addTask {
          await Self.buildOne(
            account: account,
            engine: walletSyncEngine,
            walletSyncState: walletSyncState,
            priorState: statesById[account.id])
        }
        dispatched += 1
      }
      var collected: [WalletApplyEngine.AccountInput] = []
      collected.reserveCapacity(accountList.count)
      // …then add a new task as each finishes so the group never holds
      // more than `limit` in-flight tasks at once.
      while let result = await group.next() {
        if case let .success(input) = result {
          collected.append(input)
        }
        if let next = iterator.next() {
          group.addTask {
            await Self.buildOne(
              account: next,
              engine: walletSyncEngine,
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
  static func buildOne(
    account: Account,
    engine: WalletSyncEngine,
    walletSyncState: any WalletSyncStateRepository,
    priorState: WalletSyncState?
  ) async -> PerAccountBuildResult {
    guard let chain = ChainConfig.config(for: account.chainId ?? -1) else {
      internalsLogger.notice(
        "Skipping account \(account.id, privacy: .public) — unknown chainId"
      )
      return .skipped(account.id)
    }
    do {
      let result = try await engine.build(account: account, chain: chain)
      let input = WalletApplyEngine.AccountInput(
        account: account,
        headBlockNumber: result.headBlockNumber,
        candidates: result.candidates)
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
      return .failed(account.id, walletError)
    } catch {
      let mapped = WalletSyncError.network(
        underlyingDescription: error.localizedDescription)
      await persistError(
        mapped,
        accountId: account.id,
        priorState: priorState,
        walletSyncState: walletSyncState)
      return .failed(account.id, mapped)
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
  static func persistError(
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
  /// outputs and updates the global error banner. A throwing apply pass
  /// is logged but does not surface to callers — per-account errors
  /// were already persisted in the build phase. `WalletApplyEngine`
  /// throws repository errors (GRDB / CloudKit), not `WalletSyncError`,
  /// so we don't try to translate them into the global banner.
  func runApplyPass(
    perAccountResults: [WalletApplyEngine.AccountInput]
  ) async {
    do {
      _ = try await walletApplyEngine.apply(perAccount: perAccountResults)
      // Successful apply implies the configured API key is at least
      // syntactically valid (the build phase reached Alchemy and was
      // accepted). Clear any stale banner.
      setGlobalError(nil)
    } catch {
      Self.internalsLogger.warning(
        "WalletApplyEngine apply pass failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Re-loads `statePerAccount` from the repository so observable view
  /// state matches the persisted truth after the apply pass writes
  /// `lastSyncedBlockNumber` / `lastSyncedAt` (success) or `lastError`
  /// (failure). Errors here are non-fatal — the next launch reloads.
  func refreshStateFromRepository() async {
    await reloadStatePerAccount(failureLogPrefix: "WalletSyncState refresh")
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
  static var internalsLogger: Logger {
    Logger(subsystem: "com.moolah.app", category: "CryptoSyncStore")
  }
}
