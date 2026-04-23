import SwiftUI

/// File > Import CSV… menu item plus Paste CSV. The actual handlers live in
/// the focused window's view; the commands trigger focused-value actions.
struct ImportCSVCommands: Commands {
  @FocusedValue(\.importCSVAction) private var importCSVAction
  @FocusedValue(\.pasteCSVAction) private var pasteCSVAction

  var body: some Commands {
    CommandGroup(replacing: .importExport) {
      Button("Import CSV\u{2026}") {
        importCSVAction?()
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .disabled(importCSVAction == nil)

      Button("Paste CSV") {
        pasteCSVAction?()
      }
      .keyboardShortcut("v", modifiers: [.command, .shift, .option])
      .disabled(pasteCSVAction == nil)
    }
  }
}
