import SwiftUI

/// "Notes" section: a multi-line text editor for free-form transaction notes.
struct TransactionDetailNotesSection: View {
  @Binding var notes: String

  var body: some View {
    Section("Notes") {
      TextEditor(text: $notes)
        .accessibilityLabel("Notes")
        .frame(minHeight: 60, maxHeight: 120)
    }
  }
}
