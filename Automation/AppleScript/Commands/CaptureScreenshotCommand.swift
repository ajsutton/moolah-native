#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CaptureScreenshotCommand")

  /// Handles: `capture screenshot of profile "X"`.
  ///
  /// Renders the profile window's `contentView` into an `NSBitmapImageRep`
  /// via `cacheDisplay(in:to:)` and writes a PNG inside the app container's
  /// temp directory, then returns the POSIX path of the written file.
  /// Because the app is drawing its own AppKit hierarchy in-process, the
  /// capture never goes through the WindowServer path — no Screen Recording
  /// (TCC) or Accessibility prompt is required.
  ///
  /// The output path is chosen by the app rather than the caller because
  /// Moolah's sandbox only grants `com.apple.security.files.user-selected`
  /// access — any AppleScript-supplied path outside the container would fail
  /// with a permission error. The caller `cp`s the returned path wherever
  /// it wants the screenshot to land.
  class CaptureScreenshotCommand: AppLevelScriptCommand {
    private struct CaptureFailure: Error { let message: String }

    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }

      do {
        return try MainActor.assumeIsolated {
          try Self.capture(profileName: profileName)
        }
      } catch let failure as CaptureFailure {
        scriptErrorNumber = -10000
        scriptErrorString = failure.message
        return nil
      } catch {
        scriptErrorNumber = -10000
        scriptErrorString = error.localizedDescription
        return nil
      }
    }

    @MainActor
    private static func capture(profileName: String) throws -> String {
      guard let profileStore = ScriptingContext.profileStore else {
        throw CaptureFailure(message: "Scripting not configured")
      }
      let lowered = profileName.lowercased()
      guard
        let profile = profileStore.profiles.first(where: { $0.label.lowercased() == lowered })
          ?? profileStore.profiles.first(where: { $0.id.uuidString.lowercased() == lowered })
      else {
        throw CaptureFailure(message: "Profile not found: \(profileName)")
      }
      guard let window = ProfileWindowLocator.existingWindow(for: profile.id, in: NSApp.windows)
      else {
        throw CaptureFailure(message: "Profile window not open: \(profileName)")
      }
      guard let view = window.contentView else {
        throw CaptureFailure(message: "Profile window has no content view")
      }
      let bounds = view.bounds
      guard bounds.width > 0, bounds.height > 0 else {
        throw CaptureFailure(message: "Profile window has empty content view")
      }
      guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
        throw CaptureFailure(message: "Unable to create bitmap for window content")
      }
      rep.size = bounds.size
      view.cacheDisplay(in: bounds, to: rep)
      guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CaptureFailure(message: "Unable to encode PNG")
      }
      let fileURL = outputURL()
      do {
        try data.write(to: fileURL, options: .atomic)
      } catch {
        logger.error(
          "Screenshot write failed: \(error.localizedDescription, privacy: .public)")
        throw CaptureFailure(
          message: "Failed to write screenshot: \(error.localizedDescription)")
      }
      return fileURL.path
    }

    /// Builds a unique path inside the container's temp directory.
    /// The timestamp + milliseconds suffix is collision-safe under
    /// any conceivable scripting cadence and is human-scannable in
    /// `ls`, which matters when poking around in the container.
    private static func outputURL() -> URL {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
      let stamp = formatter.string(from: Date())
      return FileManager.default.temporaryDirectory
        .appendingPathComponent("moolah-screenshot-\(stamp).png")
    }
  }
#endif
