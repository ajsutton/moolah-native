import SwiftUI

/// "Recurrence" section: a `Repeat` toggle, and when enabled, the
/// `Every <n>` interval and `Period` picker. Used for scheduled transactions.
struct TransactionDetailRecurrenceSection: View {
  @Binding var draft: TransactionDraft

  var body: some View {
    Section("Recurrence") {
      Toggle("Repeat", isOn: $draft.isRepeating)
      if draft.isRepeating {
        intervalRow
        periodPicker
      }
    }
  }

  private var intervalRow: some View {
    HStack {
      Text("Every")
      Spacer()
      TextField("", value: $draft.recurEvery, format: .number)
        #if os(iOS)
          .keyboardType(.numberPad)
        #endif
        .multilineTextAlignment(.trailing)
        .frame(minWidth: 40, idealWidth: 60, maxWidth: 80)
        .accessibilityLabel("Recurrence interval")
    }
  }

  private var periodPicker: some View {
    Picker(
      "Period",
      selection: Binding(
        get: { draft.recurPeriod ?? .month },
        set: { draft.recurPeriod = $0 }
      )
    ) {
      ForEach(RecurPeriod.allCases.filter { $0 != .once }, id: \.self) { period in
        Text(draft.recurEvery == 1 ? period.displayName : period.pluralDisplayName)
          .tag(period)
      }
    }
    .accessibilityLabel("Recurrence period")
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
  }
}
