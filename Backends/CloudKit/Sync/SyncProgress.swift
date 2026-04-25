import Foundation

/// Observable progress / phase state for `SyncCoordinator`. A single source
/// of truth consumed by `SyncProgressFooter` (sidebar) and the
/// `.heroDownloading` arm in `WelcomeStateResolver`.
///
/// All mutations happen on `@MainActor` via setter methods called from
/// `SyncCoordinator`'s existing `CKSyncEngine` event hooks. The fields
/// are `private(set)` so consumers can only read.
///
/// `pendingUploads` mirrors `syncEngine.state.pendingRecordZoneChanges.count`;
/// the engine state remains authoritative. Storing the mirror keeps SwiftUI
/// Observation invalidations reliable.
@Observable @MainActor
final class SyncProgress {
  enum Phase: Equatable {
    case idle
    case connecting
    case receiving
    case sending
    case syncing
    case upToDate
    case degraded(Reason)
  }

  enum Reason: Equatable {
    case quotaExceeded
    case iCloudUnavailable(ICloudAvailability.UnavailableReason)
    case retrying
  }

  private(set) var phase: Phase = .idle
  private(set) var recordsReceivedThisSession: Int = 0
  private(set) var pendingUploads: Int = 0
  private(set) var lastSettledAt: Date?
  private(set) var moreComing: Bool = false

  private let userDefaults: UserDefaults

  private static let lastSettledAtKey = "com.moolah.sync.lastSettledAt"

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    if let stored = userDefaults.object(forKey: Self.lastSettledAtKey) as? Date {
      self.lastSettledAt = stored
    }
  }

  // MARK: - Mutations (called by SyncCoordinator)

  /// Update the mirror of `syncEngine.state.pendingRecordZoneChanges.count`.
  /// Called whenever the coordinator queues or sends changes. When the count
  /// drops to 0:
  ///   - from `.sending`: settle (no fetch active).
  ///   - from `.syncing`: drop back to `.receiving` (fetch still going).
  ///   - otherwise: just update the mirror.
  func updatePendingUploads(_ count: Int, now: Date = Date()) {
    let wasNonzero = pendingUploads > 0
    pendingUploads = count
    guard count == 0, wasNonzero else { return }
    switch phase {
    case .sending:
      settle(now: now)
    case .syncing:
      phase = .receiving
    default:
      break
    }
  }

  /// Handles the `willFetchChanges` engine event.
  ///
  /// Routes to `.syncing` rather than `.receiving` when local changes are
  /// pending, so the UI accurately reflects that both directions are active
  /// simultaneously. No-op when in a degraded phase — the indicator should
  /// keep showing the degraded reason while sync continues in the background.
  func beginReceiving() {
    if case .degraded = phase { return }
    phase = pendingUploads > 0 ? .syncing : .receiving
  }

  /// Called for each `fetchedRecordZoneChanges` batch to accumulate
  /// received-record counts and update the `moreComing` flag.
  ///
  /// `moreComing` is overwritten on every call; the value from the most
  /// recent batch is the authoritative one. `recordsReceivedThisSession`
  /// accumulates across all batches in a session.
  func recordReceived(modifications: Int, deletions: Int, moreComing: Bool) {
    recordsReceivedThisSession += modifications + deletions
    self.moreComing = moreComing
  }

  /// Handles the `didFetchChanges` engine event.
  ///
  /// Resets the session counter and `moreComing` regardless of outcome.
  /// Settles to `.upToDate` when no uploads are pending and no degraded
  /// reason is active; routes to `.sending` when uploads still need to
  /// drain. Does not overwrite an active `.degraded` phase — the caller
  /// is responsible for clearing the degraded flag before settling.
  func endReceiving(now: Date) {
    recordsReceivedThisSession = 0
    moreComing = false
    if case .degraded = phase { return }
    if pendingUploads > 0 {
      phase = .sending
      return
    }
    settle(now: now)
  }

  // MARK: - Degraded reasons

  /// Tracks the latest active degraded reason. Setters below toggle each
  /// reason independently; `resolveDegradedPhase` picks the most specific
  /// phase. When all flags are clear, we fall back to `.idle` — callers
  /// re-enter receive/send via the normal events.
  private var quotaExceeded = false
  private var iCloudUnavailableReason: ICloudAvailability.UnavailableReason?
  private var retrying = false

  func setQuotaExceeded(_ active: Bool) {
    quotaExceeded = active
    resolveDegradedPhase()
  }

  /// Pass a concrete `reason` to enter the degraded-unavailable phase; pass
  /// `nil` to clear. The optional flavour is asymmetric with the `Bool`
  /// setters because the reason itself is the payload.
  func setICloudUnavailable(reason: ICloudAvailability.UnavailableReason?) {
    iCloudUnavailableReason = reason
    resolveDegradedPhase()
  }

  func setRetrying(_ active: Bool) {
    retrying = active
    resolveDegradedPhase()
  }

  /// Recompute `.phase` from the active degraded flags. Priority order:
  /// quota wins over iCloud availability wins over retry, because each is
  /// more actionable than the last.
  private func resolveDegradedPhase() {
    if quotaExceeded {
      phase = .degraded(.quotaExceeded)
      return
    }
    if let reason = iCloudUnavailableReason {
      phase = .degraded(.iCloudUnavailable(reason))
      return
    }
    if retrying {
      phase = .degraded(.retrying)
      return
    }
    if case .degraded = phase {
      phase = .idle
    }
  }

  // MARK: - Persistence

  /// Single settle transition — used by both the `didFetchChanges` settle
  /// path and the upload-drain path. Centralised so any future settle
  /// side-effect (telemetry, notifications, extra fields) lands in one place.
  private func settle(now: Date) {
    phase = .upToDate
    lastSettledAt = now
    persistLastSettledAt()
  }

  private func persistLastSettledAt() {
    if let lastSettledAt {
      userDefaults.set(lastSettledAt, forKey: Self.lastSettledAtKey)
    } else {
      userDefaults.removeObject(forKey: Self.lastSettledAtKey)
    }
  }
}
