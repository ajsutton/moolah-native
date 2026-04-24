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

  static let lastSettledAtKey = "com.moolah.sync.lastSettledAt"

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    if let stored = userDefaults.object(forKey: Self.lastSettledAtKey) as? Date {
      self.lastSettledAt = stored
    }
  }
}
