import Foundation
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

// MARK: - Pasteboard / browser defaults

extension SyncedAccountHeaderView {
  /// Platform-default clipboard write. Lives on the view so tests can
  /// substitute a recording closure via the initialiser without touching
  /// the system pasteboard.
  static func defaultCopy(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }

  /// Platform-default URL opener. Lives on the view so tests can
  /// substitute a recording closure without spawning a real browser.
  static func defaultOpen(_ url: URL) {
    #if os(macOS)
      NSWorkspace.shared.open(url)
    #else
      UIApplication.shared.open(url)
    #endif
  }
}
