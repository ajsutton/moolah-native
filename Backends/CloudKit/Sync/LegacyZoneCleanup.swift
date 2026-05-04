import CloudKit
import Foundation
import OSLog

/// One-time cleanup of the legacy `com.apple.coredata.cloudkit.zone` zone.
///
/// SwiftData's automatic CloudKit sync used this hardcoded zone for all data.
/// Since we've migrated to CKSyncEngine with per-profile zones, this old zone
/// contains stale data that should be removed.
///
/// This is safe for a pre-release app — no backward compatibility needed.
enum LegacyZoneCleanup {
  private static let cleanupKey = "com.moolah.legacyZoneCleanupDone"
  private static let legacyZoneName = "com.apple.coredata.cloudkit.zone"
  private static let logger = Logger(subsystem: "com.moolah.app", category: "LegacyZoneCleanup")

  /// Performs the one-time cleanup if not already done.
  /// Call this at app launch. It's a no-op if cleanup was already performed.
  ///
  /// - Parameter defaults: `UserDefaults` instance used to persist the
  ///   "cleanup done" flag. Tests can pass an isolated suite to avoid
  ///   touching the user's standard defaults.
  @MainActor
  static func performIfNeeded(defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: cleanupKey) else { return }
    Task { @MainActor in
      await deleteLegacyZone(defaults: defaults)
    }
  }

  @MainActor
  private static func deleteLegacyZone(defaults: UserDefaults) async {
    let database = CloudKitContainer.app.privateCloudDatabase
    let legacyZoneID = CKRecordZone.ID(
      zoneName: legacyZoneName,
      ownerName: CKCurrentUserDefaultName
    )

    do {
      // Check if the zone exists
      let zones = try await database.allRecordZones()
      guard zones.contains(where: { $0.zoneID == legacyZoneID }) else {
        logger.info("Legacy zone not found, marking cleanup as done")
        defaults.set(true, forKey: cleanupKey)
        return
      }

      // Delete the zone (this deletes all records in it)
      try await database.deleteRecordZone(withID: legacyZoneID)
      logger.info("Successfully deleted legacy CloudKit zone")
      defaults.set(true, forKey: cleanupKey)
    } catch {
      // Don't mark as done on failure — will retry next launch
      logger.error("Failed to delete legacy zone: \(error, privacy: .public)")
    }
  }
}
