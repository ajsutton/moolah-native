// Features/Crypto/CryptoSyncStore.swift
import Foundation
import OSLog
import Observation
import SwiftUI

/// `@MainActor @Observable` orchestrator for the wallet auto-import.
/// Owns the foreground sync timer, the per-account "Sync now" command,
/// and per-account observable state (last-synced, sync-in-progress,
/// last-error).
///
/// Cancellation discipline (per design §"Sync trigger taxonomy"):
///
/// - On scenePhase `.active`: cancel any prior `timerTask`, then assign
///   a new `Task { await runTimerLoop() }` to `timerTask`.
/// - On `.background` / `.inactive`: cancel `timerTask` and clear it.
/// - The loop body checks `Task.isCancelled` immediately after every
///   `Task.sleep(for:)` suspension before dispatching the next sync
///   batch and before sleeping again. A cancelled task exits cleanly
///   without writing state.
///
/// `BackgroundTasks` (`BGAppRefreshTask`) is explicitly out of scope.
///
/// Concurrency model: parallel build via `withTaskGroup` (up to 4
/// concurrent per-account tasks), then a single sequential `@MainActor`
/// apply pass via `WalletApplyEngine`. Per-account error containment is
/// built into the build phase — a failing account writes
/// `WalletSyncState.lastError` and does not abort other accounts.
@MainActor
@Observable
final class CryptoSyncStore {
  /// Per-account in-flight markers. Used both as observable view state
  /// (so a row can show a spinner) and as a guard against concurrent
  /// duplicate launches: `syncStaleAccounts` and `syncAccount` skip an
  /// account already present here, so a second trigger while the first
  /// is still running collapses to the single in-flight sync.
  private(set) var inProgressAccountIds: Set<UUID> = []

  /// Per-account sync state (`lastSyncedAt`, `lastSyncedBlockNumber`,
  /// `lastError`) keyed by account id. Loaded from
  /// `WalletSyncStateRepository.loadAll()` at launch and refreshed after
  /// every apply pass so the wallet account view + settings UI re-render
  /// without another round-trip.
  private(set) var statePerAccount: [UUID: WalletSyncState] = [:]

  /// Banner-level error visible across the crypto-settings UI when a
  /// process-wide failure (`.missingApiKey` / `.invalidApiKey`) means
  /// no account can sync at all. `nil` once any sync cycle succeeds.
  /// Per-account network/rate-limit/malformed errors are stored on
  /// `statePerAccount[id].lastError` instead.
  private(set) var globalError: WalletSyncError?

  // Internal (default) access so the helpers in
  // `CryptoSyncStore+Internals.swift` can read these without bouncing
  // through accessor methods. The properties remain `let` so the store
  // is still effectively immutable from outside this module's
  // extensions.
  let walletSyncEngine: WalletSyncEngine
  let walletApplyEngine: WalletApplyEngine
  let walletSyncState: any WalletSyncStateRepository
  let accounts: any AccountRepository
  let clock: @Sendable () -> Date
  let staleThreshold: TimeInterval
  let timerInterval: Duration
  let maxConcurrentBuilds: Int

  /// Hourly stale-check timer. Owned by the store; cancelled on
  /// scenePhase `.background`/`.inactive`; recreated on `.active`.
  /// `nil` outside an active scene. Module-internal write so the
  /// `+Internals` extension can swap the task on `.active`.
  var timerTask: Task<Void, Never>?

  /// Tracks the last `.active`-triggered immediate sync so a rapid
  /// scene-phase cycle (e.g. dragging a window across Spaces) cancels
  /// the prior fire-and-forget instead of stacking. Per
  /// `guides/CONCURRENCY_GUIDE.md` §8 — fire-and-forget tasks must be
  /// tracked so teardown can cancel them.
  var sceneActiveSyncTask: Task<Void, Never>?

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoSyncStore")

  /// - Parameters:
  ///   - walletSyncEngine: Per-account build orchestrator (Stage 6).
  ///   - walletApplyEngine: Sequential `@MainActor` apply pass (Stage 7).
  ///   - walletSyncState: Per-device sync checkpoint store.
  ///   - accounts: Account repository — read on every stale check to
  ///     filter `type == .crypto`.
  ///   - clock: Closure returning "now". The clock injection is for
  ///     per-account `lastSyncedAt` decisions; the timer's
  ///     `Task.sleep` uses the real Swift clock regardless. Tests pass
  ///     a pinned closure.
  ///   - staleThreshold: Seconds before an account is considered stale
  ///     since the last successful sync. Default 24 hours.
  ///   - timerInterval: Hourly stale-check cadence. Default 1 hour.
  ///   - maxConcurrentBuilds: Cap on simultaneous per-account fetches in
  ///     the parallel build phase. Default 4 (per design).
  init(
    walletSyncEngine: WalletSyncEngine,
    walletApplyEngine: WalletApplyEngine,
    walletSyncState: any WalletSyncStateRepository,
    accounts: any AccountRepository,
    clock: @Sendable @escaping () -> Date = { Date() },
    staleThreshold: TimeInterval = 86_400,
    timerInterval: Duration = .seconds(3_600),
    maxConcurrentBuilds: Int = 4
  ) {
    self.walletSyncEngine = walletSyncEngine
    self.walletApplyEngine = walletApplyEngine
    self.walletSyncState = walletSyncState
    self.accounts = accounts
    self.clock = clock
    self.staleThreshold = staleThreshold
    self.timerInterval = timerInterval
    self.maxConcurrentBuilds = max(1, maxConcurrentBuilds)
  }

  // MARK: - Public sync triggers

  /// Bootstraps observable state from persisted checkpoints. Call once
  /// at app launch (e.g. from the root scene `.task`). Failure is
  /// non-fatal — the next sync cycle still runs against an empty cache.
  func loadInitialState() async {
    await reloadStatePerAccount(failureLogPrefix: "Initial WalletSyncState load")
  }

  /// Sync any crypto account whose `lastSyncedAt` is older than
  /// `staleThreshold` (24 h by default). Used by app-launch, scene-active,
  /// and the hourly timer. A no-op when nothing is stale.
  ///
  /// Per-account error containment is preserved: failures inside the
  /// build phase write `WalletSyncState.lastError` and don't abort other
  /// accounts in the same cycle.
  func syncStaleAccounts() async {
    let stale = await accountsToSync(includeNonStale: false)
    guard !stale.isEmpty else { return }
    await syncAccounts(stale)
  }

  /// User-initiated sync of a specific account, regardless of staleness.
  /// Skips when the account is already mid-sync (the existing in-flight
  /// task wins; the user-initiated one collapses to a no-op rather than
  /// queueing a duplicate write).
  func syncAccount(_ account: Account) async {
    guard account.type == .crypto else { return }
    guard !inProgressAccountIds.contains(account.id) else { return }
    await syncAccounts([account])
  }

  // MARK: - Lifecycle

  /// Call from `.onChange(of: scenePhase)` in the root scene. Owns the
  /// timer's lifecycle: started fresh on `.active` (after cancelling any
  /// prior task) and torn down on `.background` / `.inactive`.
  func handleScenePhaseChange(_ newPhase: ScenePhase) {
    switch newPhase {
    case .active:
      restartTimer()
      sceneActiveSyncTask?.cancel()
      sceneActiveSyncTask = Task { [weak self] in
        await self?.syncStaleAccounts()
      }
    case .background, .inactive:
      cancelTimer()
    @unknown default:
      break
    }
  }

  /// Cancels and clears the hourly stale-check timer plus any
  /// in-flight scene-active sync. Safe to call when no task is
  /// running. Exposed for `ProfileSession.cleanupSync` so neither task
  /// outlives a profile teardown.
  func cancelTimer() {
    timerTask?.cancel()
    timerTask = nil
    sceneActiveSyncTask?.cancel()
    sceneActiveSyncTask = nil
  }

  // MARK: - Sync algorithm (parallel build → sequential apply)

  /// Sync the given accounts via the parallel-build → sequential-apply
  /// algorithm. Internal seam — used by `syncStaleAccounts`,
  /// `syncAccount`, and the timer loop. Marked `internal` so tests can
  /// drive a deterministic account list directly.
  ///
  /// Algorithm:
  /// 1. Mark every account as in-flight on `@MainActor`.
  /// 2. Run up to `maxConcurrentBuilds` parallel build tasks via
  ///    `withTaskGroup`. Each task either produces a
  ///    `WalletSyncBuildResult` or records a `lastError` on the account's
  ///    `WalletSyncState` and produces nothing.
  /// 3. Apply collected results sequentially through `WalletApplyEngine`.
  /// 4. Refresh `statePerAccount` from the repository so observable view
  ///    state matches the persisted truth.
  /// 5. Clear in-flight markers.
  func syncAccounts(_ accountList: [Account]) async {
    let inputs = accountList.filter { account in
      guard account.type == .crypto else { return false }
      // Re-skip anything already in flight from a prior trigger; this
      // is the load-bearing collapse-duplicates check exercised by the
      // concurrent-trigger test.
      guard !inProgressAccountIds.contains(account.id) else { return false }
      return true
    }
    guard !inputs.isEmpty else { return }

    for account in inputs { inProgressAccountIds.insert(account.id) }
    defer {
      for account in inputs { inProgressAccountIds.remove(account.id) }
    }

    let perAccountResults = await runParallelBuilds(for: inputs)
    await runApplyPass(perAccountResults: perAccountResults)
    await refreshStateFromRepository()
  }

  // MARK: - Internal mutators

  /// Setter shim so `CryptoSyncStore+Internals.swift` extension methods
  /// can update observable state. The store's public surface keeps
  /// `private(set)` for `globalError` so views can only observe — the
  /// shim is internal, not public.
  func setGlobalError(_ error: WalletSyncError?) {
    globalError = error
  }

  /// Replaces the entire `statePerAccount` map. Used by the apply-phase
  /// refresh after a sync cycle so the in-memory view of checkpoint
  /// state matches the persisted truth.
  func replaceStatePerAccount(_ map: [UUID: WalletSyncState]) {
    statePerAccount = map
  }

  /// Loads every persisted checkpoint into `statePerAccount`. Shared
  /// between launch bootstrap and the post-apply refresh; the
  /// `failureLogPrefix` distinguishes the two call sites in the log.
  func reloadStatePerAccount(failureLogPrefix: String) async {
    do {
      let states = try await walletSyncState.loadAll()
      var map: [UUID: WalletSyncState] = [:]
      map.reserveCapacity(states.count)
      for state in states { map[state.id] = state }
      replaceStatePerAccount(map)
    } catch {
      Self.logger.error(
        "\(failureLogPrefix, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // Implementation helpers (parallel build, apply pass, timer loop)
  // live in `CryptoSyncStore+Internals.swift` so this file stays under
  // SwiftLint's `file_length` and `type_body_length` budgets.
}
