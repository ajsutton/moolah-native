import SwiftUI

/// "Earmark funds" section: the only editable section for a simple
/// earmark-only transaction (no account leg). Renders an immutable type
/// label, the earmark picker, the amount field, and the date picker.
struct TransactionDetailEarmarkOnlySection: View {
  @Binding var draft: TransactionDraft
  let earmarks: Earmarks
  let amountBinding: Binding<String>

  /// Bridges `LegDraft.instrument` (`Instrument?`) to the picker's
  /// non-optional binding. Falls back to the earmark's instrument when
  /// the leg has no explicit override (and finally `.AUD` so the picker
  /// always has something to display); writes go to the leg.
  private var earmarkInstrumentBinding: Binding<Instrument> {
    Binding(
      get: {
        draft.legDrafts[draft.relevantLegIndex].instrument
          ?? draft.relevantLeg.earmarkId
          .flatMap { earmarks.by(id: $0) }?
          .instrument
          ?? .AUD
      },
      set: { draft.legDrafts[draft.relevantLegIndex].instrument = $0 }
    )
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

      LabeledContent {
        HStack(spacing: 8) {
          TextField("Amount", text: amountBinding)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif
          CompactInstrumentPickerButton(selection: earmarkInstrumentBinding)
        }
      } label: {
        Text("Amount")
      }

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }
}
