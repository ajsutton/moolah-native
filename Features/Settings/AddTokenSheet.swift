// Features/Settings/AddTokenSheet.swift
import SwiftUI

/// Search-only Add Token flow. Embeds the shared `InstrumentPickerSheet`
/// limited to crypto results; the picker handles resolution and registration
/// internally. `onRegistered` fires once when a token is successfully picked
/// (and therefore added to the registry); the sheet then dismisses.
///
/// The fixed minimum frame matches `InstrumentPickerField`'s popover sizing
/// (460×480) so the picker has room for results plus the footer hint;
/// without it SwiftUI sizes the sheet to the empty-state view's intrinsic
/// content and the first row presented after a search renders outside the
/// hit-testable bounds.
struct AddTokenSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onRegistered: () -> Void

  var body: some View {
    InstrumentPickerSheet(kinds: [.cryptoToken]) { instrument in
      if instrument != nil { onRegistered() }
      dismiss()
    }
    .frame(minWidth: 460, minHeight: 480)
  }
}
