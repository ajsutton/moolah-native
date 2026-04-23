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
    case .active:
      Task { await fetchRemoteChanges() }
    default:
      break
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

  // MARK: - URL Scheme Handling

  func handleURL(_ url: URL) {
    // CSV files opened via Finder "Open With Moolah" or dropped on the
    // Dock icon arrive as `file://` URLs. Post a notification — the
    // active profile's `ContentView` is subscribed and will route it
    // through `ImportStore.ingest` (matcher auto-routes, unknown files
    // land in Needs Setup) exactly like a drag-and-drop.
    if url.isFileURL && url.pathExtension.lowercased() == "csv" {
      NotificationCenter.default.post(name: .openCSVFile, object: url)
      return
    }
    do {
      let route = try URLSchemeHandler.parse(url)
      // Find profile by name (case-insensitive) then by UUID
      if let profile = profileStore.profiles.first(where: {
        $0.label.lowercased() == route.profileIdentifier.lowercased()
      })
        ?? profileStore.profiles.first(where: {
          $0.id.uuidString.lowercased() == route.profileIdentifier.lowercased()
        })
      {
        #if os(macOS)
          openWindow(value: profile.id)
        #else
          profileStore.setActiveProfile(profile.id)
        #endif
        if let destination = route.destination {
          pendingNavigation = PendingNavigation(
            profileId: profile.id, destination: destination)
        }
      } else {
        logger.warning(
          "No profile found matching '\(route.profileIdentifier, privacy: .public)'")
      }
    } catch {
      logger.error("Failed to parse URL: \(error.localizedDescription, privacy: .public)")
    }
  }
}
