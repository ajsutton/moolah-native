import SwiftUI

/// "Earmark funds" section: the only editable section for a simple
/// earmark-only transaction (no account leg). Renders an immutable type
/// label, the earmark picker, the amount field, and the date picker.
struct TransactionDetailEarmarkOnlySection: View {
  @Binding var draft: TransactionDraft
  let earmarks: Earmarks
  let amountBinding: Binding<String>

  /// Instrument code label shown next to the amount field. Derived from
  /// the earmark on the draft's relevant leg.
  private var earmarkInstrumentId: String? {
    draft.relevantLeg.earmarkId
      .flatMap { earmarks.by(id: $0) }?
      .instrument.id
  }

  var body: some View {
    Section {
      LabeledContent("Type") {
        Text("Earmark funds")
          .foregroundStyle(.secondary)
      }

      Picker("Earmark", selection: $draft.earmarkId) {
        ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
          Text(earmark.name).tag(UUID?.some(earmark.id))
        }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif

      HStack {
        TextField("Amount", text: amountBinding)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
        Text(earmarkInstrumentId ?? "").foregroundStyle(.secondary)
          .monospacedDigit()
      }

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }
}
