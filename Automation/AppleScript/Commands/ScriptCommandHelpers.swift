#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "ScriptCommand")

  /// Thread-safe box for transferring results across actor boundaries via semaphore.
  /// The semaphore ensures happens-before ordering between write (in Task) and read (after wait).
  final class ScriptResultBox<T: Sendable>: @unchecked Sendable {
    var value: T?
    var error: String?
  }

  extension NSScriptCommand {

    /// Resolves the profile name from the direct parameter (an object specifier).
    /// AppleScript commands typically pass a specifier like `profile "MyProfile"`.
    func resolveProfileName() -> String? {
      if let specifier = directParameter as? NSScriptObjectSpecifier {
        // NSNameSpecifier: `profile "MyProfile"`
        if let nameSpec = specifier as? NSNameSpecifier {
          return nameSpec.name
        }
      }
      // Direct parameter might be a string
      if let name = directParameter as? String {
        return name
      }
      return nil
    }

    /// Runs an async MainActor block synchronously, suitable for NSScriptCommand handlers.
    /// Uses a semaphore to bridge async/sync. This is safe because NSScriptCommand handlers
    /// run on a dedicated Apple Events thread, not the main thread.
    func runBlockingWithError<T: Sendable>(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending T
    ) -> T? {
      guard !Thread.isMainThread else {
        logger.error("runBlockingWithError called on main thread - would deadlock")
        scriptErrorNumber = errOSAGeneralError
        scriptErrorString = "Internal error: scripting command ran on main thread"
        return nil
      }

      let box = ScriptResultBox<T>()
      let semaphore = DispatchSemaphore(value: 0)

      Task { @MainActor in
        do {
          box.value = try await operation()
        } catch {
          box.error = error.localizedDescription
        }
        semaphore.signal()
      }

      semaphore.wait()

      if let errorMessage = box.error {
        logger.error("Script command failed: \(errorMessage)")
        scriptErrorNumber = errOSAGeneralError
        scriptErrorString = errorMessage
        return nil
      }

      return box.value
    }
  }

  /// Error codes for AppleScript
  private let errOSAGeneralError: Int = -10000
#endif
