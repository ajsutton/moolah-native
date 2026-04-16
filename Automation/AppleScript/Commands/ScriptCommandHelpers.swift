#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "ScriptCommand")

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
    func runBlockingWithError<T>(_ operation: @escaping @MainActor @Sendable () async throws -> T)
      -> T?
    {
      guard !Thread.isMainThread else {
        logger.error("runBlockingWithError called on main thread - would deadlock")
        scriptErrorNumber = errOSAGeneralError
        scriptErrorString = "Internal error: scripting command ran on main thread"
        return nil
      }

      nonisolated(unsafe) var result: T?
      nonisolated(unsafe) var caughtError: String?
      let semaphore = DispatchSemaphore(value: 0)

      Task { @MainActor in
        do {
          result = try await operation()
        } catch {
          caughtError = error.localizedDescription
        }
        semaphore.signal()
      }

      semaphore.wait()

      if let errorMessage = caughtError {
        logger.error("Script command failed: \(errorMessage)")
        scriptErrorNumber = errOSAGeneralError
        scriptErrorString = errorMessage
        return nil
      }

      return result
    }
  }

  /// Error codes for AppleScript
  private let errOSAGeneralError: Int = -10000
#endif
