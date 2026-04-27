// Features/Settings/AddTokenSheet.swift
import SwiftUI

/// Search-only Add Token flow. Embeds the shared `InstrumentPickerSheet`
/// limited to crypto results; the picker handles resolution and registration
/// internally. `onRegistered` fires once when a token is successfully picked
/// (and therefore added to the registry); the sheet then dismisses.
struct AddTokenSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onRegistered: () -> Void

  var body: some View {
    InstrumentPickerSheet(kinds: [.cryptoToken]) { instrument in
      if instrument != nil { onRegistered() }
      dismiss()
    }
  }
}
