// Backends/CloudKit/Sync/SyncCoordinator+CrossDeviceLegDedup.swift

@preconcurrency import CloudKit
import Foundation
import OSLog

/// Cross-device leg dedup hook for the post-fetch path.
///
/// Wiring contract:
/// - `extractTouchedExternalIds(saved:)` runs **off-main** in the same
///   pre-apply window that builds the handler, so the read happens
///   before `applyRemoteChanges` mutates row state.
/// - `runCrossDeviceLegDedup(profileId:touchedExternalIds:)` runs **on
///   `@MainActor`** after the apply succeeds. It uses the cached
///   `ProfileGRDBRepositories.transactions` (already populated by
///   `resolveGRDBRepositories`) so there is no extra DI plumbing.
/// - All deletes route through `TransactionRepository.delete(id:)`
///   inside `CrossDeviceLegDeduper`. The repository's `onRecordDeleted`
///   hook then propagates the change back through CKSyncEngine. See
///   `plans/2026-05-05-crypto-wallet-import-design.md` §"Multi-device
///   race window".
extension SyncCoordinator {
  /// Returns every non-nil `externalId` value carried by saved
  /// `TransactionLegRecord` CKRecords. Drives the post-apply
  /// `CrossDeviceLegDeduper` sweep — only legs whose key the
  /// just-applied fetch could have touched are revisited.
  ///
  /// Reads `externalId` directly off the CKRecord rather than
  /// re-decoding through `TransactionLegRecordCloudKitFields` because
  /// the deduper only needs the externalId scope hint, not the full
  /// row. The field name is part of the CloudKit wire contract — same
  /// constant the GRDB sync layer uses on the write path.
  nonisolated static func extractTouchedExternalIds(
    saved: [CKRecord]
  ) -> Set<String> {
    var touched: Set<String> = []
    for record in saved where record.recordType == TransactionLegRow.recordType {
      if let externalId = record["externalId"] as? String {
        touched.insert(externalId)
      }
    }
    return touched
  }

  /// Runs `CrossDeviceLegDeduper` against the per-profile transaction
  /// repository on `@MainActor`. The repository handle is fetched off
  /// the cached `ProfileGRDBRepositories` bundle the apply path
  /// already builds — no extra DI plumbing. Best-effort: the deduper
  /// catches and logs any per-delete failure internally, so a thrown
  /// error here is the rare case where even the touched-set query
  /// failed and means the next fetch will retry the sweep.
  @MainActor
  func runCrossDeviceLegDedup(
    profileId: UUID, touchedExternalIds: Set<String>
  ) async {
    guard !touchedExternalIds.isEmpty else { return }
    guard let repositories = cachedGRDBRepositories[profileId] else {
      // The bundle is populated on first apply via
      // `resolveGRDBRepositories(for:)`; we just ran that path above
      // to build the handler, so missing-here means the cache was
      // evicted between the handler build and now (e.g. profile
      // removal). Skip silently — there's nothing to clean up.
      return
    }
    let deduper = CrossDeviceLegDeduper(transactions: repositories.transactions)
    do {
      let collapsed = try await deduper.dedup(touchedExternalIds: touchedExternalIds)
      if collapsed > 0 {
        logger.info(
          "CrossDeviceLegDeduper collapsed \(collapsed, privacy: .public) duplicate transaction(s) for profile \(profileId, privacy: .public)"
        )
      }
    } catch {
      logger.error(
        "CrossDeviceLegDeduper failed for profile \(profileId, privacy: .public): \(error, privacy: .public)"
      )
    }
  }
}
