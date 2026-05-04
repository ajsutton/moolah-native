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
      // Tracked + cancellable via SyncCoordinator. Rapid scene-phase
      // cycling (e.g. dragging a window across Spaces) can call this
      // repeatedly; the coordinator cancels the prior task before
      // launching a new one so concurrent fetches don't stack.
      logger.info("Fetching remote changes on foreground entry")
      syncCoordinator.scheduleFetchChanges()
    default:
      break
    }
  }

  /// Per `guides/DATABASE_SCHEMA_GUIDE.md` §5, the recommended cadence for
  /// `PRAGMA optimize` is "once on app resign-active and at most once per
  /// hour while active". This handler covers the resign-active half by
  /// asking each open session to schedule its own tracked optimize task —
  /// the session stores the handle and cancels it on teardown, so this
  /// loop never leaks fire-and-forget Tasks. The hourly-while-active half
  /// is owned by `ProfileSession.startPeriodicPragmaOptimize(interval:)`,
  /// which is started from the session initialiser.
  func runPragmaOptimizeOnAllSessions() {
    for session in sessionManager.openProfiles {
      session.schedulePragmaOptimize()
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
