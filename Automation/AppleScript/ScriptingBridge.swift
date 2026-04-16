#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "ScriptingBridge")

  /// Bridges the SwiftUI app to the AppleScript object model.
  /// Registered as the NSApplicationDelegate via @NSApplicationDelegateAdaptor.
  /// Exposes scriptableProfiles as the top-level element that NSApplication resolves
  /// via KVC for the SDEF's application class.
  class ScriptingBridge: NSObject, NSApplicationDelegate {

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
      logger.info("Scripting bridge ready")
    }

    /// Tells the scripting infrastructure which keys the application handles.
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
      key == "scriptableProfiles"
    }

    /// The top-level scripting element: all open profiles.
    /// Called by the scripting infrastructure when AppleScript accesses `profiles of application`.
    @objc var scriptableProfiles: [ScriptableProfile] {
      // This is called from the Apple Events thread. We need to hop to MainActor
      // to access the session manager safely.
      guard !Thread.isMainThread else {
        logger.warning("scriptableProfiles accessed on main thread - returning empty")
        return []
      }

      final class ResultBox: @unchecked Sendable {
        var profiles: [ScriptableProfile] = []
      }
      let box = ResultBox()
      let semaphore = DispatchSemaphore(value: 0)

      Task { @MainActor in
        if let sessionManager = ScriptingContext.sessionManager {
          box.profiles = sessionManager.openProfiles.map { ScriptableProfile(session: $0) }
        } else {
          logger.warning("ScriptingBridge accessed before configuration")
        }
        semaphore.signal()
      }

      semaphore.wait()
      return box.profiles
    }
  }
#endif
