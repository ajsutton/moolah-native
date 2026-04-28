import Foundation
import SwiftUI

// Scene-phase sync flushing and URL-scheme routing extracted from the main
// `MoolahApp` body so it stays under SwiftLint's `type_body_length` threshold.
extension MoolahApp {

  // MARK: - Background Sync

  func handleScenePhaseChange(_ newPhase: ScenePhase) {
    switch newPhase {
    case .background:
      flushPendingChanges()
      runPragmaOptimizeOnAllSessions()
    case .active:
      Task { await fetchRemoteChanges() }
    default:
      break
    }
  }

  /// Per `guides/DATABASE_SCHEMA_GUIDE.md` §5, the recommended cadence for
  /// `PRAGMA optimize` is "once on app resign-active". Iterates the open
  /// profile sessions and dispatches a best-effort optimize on each. The
  /// hourly-while-active tick is a follow-up — current rate-cache schemas
  /// are small enough that once-per-resign suffices.
  func runPragmaOptimizeOnAllSessions() {
    let sessions = sessionManager.openProfiles
    for session in sessions {
      Task { await session.runPragmaOptimize() }
    }
  }

  func flushPendingChanges() {
    guard syncCoordinator.hasPendingChanges else {
      logger.debug("No pending changes to flush on background entry")
      return
    }

    logger.info("Flushing pending sync changes on background entry")

    #if os(iOS)
      // Request extra background time on iOS to complete uploads.
      // On macOS the app process stays alive, so no special handling is needed.
      ProcessInfo.processInfo.performExpiringActivity(
        withReason: "Uploading pending sync changes"
      ) { expired in
        guard !expired else { return }
        Task { @MainActor in
          await self.syncCoordinator.sendChanges()
        }
      }
    #else
      Task {
        await syncCoordinator.sendChanges()
      }
    #endif
  }

  func fetchRemoteChanges() async {
    logger.info("Fetching remote changes on foreground entry")
    await syncCoordinator.fetchChanges()
  }

  // MARK: - URL Handling

  /// CSV files opened via Finder "Open With Moolah" or dropped on the Dock
  /// icon arrive here as `file://` URLs. Post a notification — the active
  /// profile's `ContentView` is subscribed and will route it through
  /// `ImportStore.ingest` (matcher auto-routes, unknown files land in
  /// Needs Setup) exactly like a drag-and-drop.
  func handleURL(_ url: URL) {
    guard url.isFileURL, url.pathExtension.lowercased() == "csv" else { return }
    NotificationCenter.default.post(name: .openCSVFile, object: url)
  }
}
