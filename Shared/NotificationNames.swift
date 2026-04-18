import Foundation

/// Cross-platform `Notification.Name` constants used by menu-bar commands to request
/// actions from the focused window's views. The commands (macOS-only) post these
/// notifications; the views (shared) listen via `.onReceive`. Keeping the names
/// outside `#if os(macOS)` lets both compile.
extension Notification.Name {
  // Transaction commands
  static let requestTransactionEdit = Notification.Name("requestTransactionEdit")
  static let requestTransactionDuplicate = Notification.Name("requestTransactionDuplicate")
  static let requestTransactionDelete = Notification.Name("requestTransactionDelete")

  // Account commands
  static let requestAccountEdit = Notification.Name("requestAccountEdit")

  // Earmark commands
  static let requestEarmarkEdit = Notification.Name("requestEarmarkEdit")
  static let requestEarmarkToggleHidden = Notification.Name("requestEarmarkToggleHidden")
}
