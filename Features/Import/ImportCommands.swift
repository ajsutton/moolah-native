import SwiftUI

/// File > Import CSV… menu item. The actual `.fileImporter` sheet lives in
/// the focused window's view; this command triggers the focused-value action
/// that opens it.
struct ImportCSVCommands: Commands {
  @FocusedValue(\.importCSVAction) private var importCSVAction

  var body: some Commands {
    CommandGroup(replacing: .importExport) {
      Button("Import CSV\u{2026}") {
        importCSVAction?()
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .disabled(importCSVAction == nil)
    }
  }
}
