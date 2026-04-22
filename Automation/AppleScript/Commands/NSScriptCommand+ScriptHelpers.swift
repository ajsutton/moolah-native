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

  /// Sendable wrapper so a non-Sendable `NSScriptCommand` can be handed to a
  /// `@MainActor` `Task` without tripping Swift 6 isolation checks. The command
  /// is only ever read on `@MainActor`, matching Cocoa's scripting dispatch.
  final class ScriptCommandBox: @unchecked Sendable {
    let command: NSScriptCommand

    init(_ command: NSScriptCommand) { self.command = command }
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

    /// Runs an async MainActor block from an `NSScriptCommand.performDefaultImplementation`.
    ///
    /// Cocoa's scripting infrastructure on macOS 26 dispatches commands on the
    /// main thread, so the historical "bridge async → sync via semaphore" trick
    /// deadlocks: the `Task { @MainActor in ... }` can never run because
    /// `semaphore.wait()` is blocking the very thread it needs. On main, this
    /// helper instead uses `NSScriptCommand.suspendExecution()` and resumes
    /// asynchronously when the operation completes — `performDefaultImplementation`
    /// returns `nil` immediately, and the real result is delivered later via
    /// `resumeExecution(withResult:)`. Off-main (vestigial, for whatever dedicated
    /// thread Cocoa might use in future) it still blocks on a semaphore.
    func runBlockingWithError<T: Sendable>(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending T
    ) -> T? {
      if Thread.isMainThread {
        suspendExecution()
        let commandBox = ScriptCommandBox(self)
        Task { @MainActor in
          do {
            let value = try await operation()
            commandBox.command.resumeExecution(withResult: value)
          } catch {
            logger.error(
              "Script command failed: \(error.localizedDescription, privacy: .public)")
            commandBox.command.scriptErrorNumber = errOSAGeneralError
            commandBox.command.scriptErrorString = error.localizedDescription
            commandBox.command.resumeExecution(withResult: nil)
          }
        }
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
