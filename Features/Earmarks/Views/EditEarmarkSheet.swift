import SwiftUI

struct EditEarmarkSheet: View {
  let earmark: Earmark
  let supportsComplexTransactions: Bool
  let onUpdate: (Earmark) -> Void

  @State private var name: String
  @State private var currency: Instrument
  @State private var savingsGoal: String
  @State private var startDate: Date
  @State private var endDate: Date
  @State private var useDateRange: Bool
  @State private var isHidden: Bool
  @Environment(\.dismiss) private var dismiss

  init(
    earmark: Earmark,
    supportsComplexTransactions: Bool = false,
    onUpdate: @escaping (Earmark) -> Void
  ) {
    self.earmark = earmark
    self.supportsComplexTransactions = supportsComplexTransactions
    self.onUpdate = onUpdate
    _name = State(initialValue: earmark.name)
    _currency = State(initialValue: earmark.instrument)
    _savingsGoal = State(initialValue: earmark.savingsGoal?.decimalValue.description ?? "")
    _startDate = State(initialValue: earmark.savingsStartDate ?? Date())
    _endDate = State(
      initialValue: earmark.savingsEndDate
        ?? Calendar.current.date(byAdding: .year, value: 1, to: Date())
        ?? Date())
    _useDateRange = State(
      initialValue: earmark.savingsStartDate != nil || earmark.savingsEndDate != nil)
    _isHidden = State(initialValue: earmark.isHidden)
  }

  private var selectedInstrument: Instrument {
    supportsComplexTransactions ? currency : earmark.instrument
  }

  var body: some View {
    NavigationStack {
      form
    }
    #if os(macOS)
      .frame(minWidth: 400, minHeight: 300)
    #endif
  }

  private var form: some View {
    Form {
      Section("Details") {
        TextField("Name", text: $name)
          .accessibilityLabel("Earmark name")
        if supportsComplexTransactions {
          InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
        } else {
          LabeledContent("Currency") {
            Text(earmark.instrument.displayLabel)
              .foregroundStyle(.secondary)
          }
        }
        Toggle("Hidden", isOn: $isHidden)
      }

      Section("Savings Goal") {
        HStack {
          Text(selectedInstrument.displayLabel)
            .foregroundStyle(.secondary)
          TextField("Amount", text: $savingsGoal)
            .monospacedDigit()
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif
        }
        Toggle("Set Date Range", isOn: $useDateRange)
        if useDateRange {
          DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
          DatePicker("End Date", selection: $endDate, displayedComponents: .date)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Edit Earmark")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { saveChanges() }
          .disabled(name.isEmpty)
      }
    }
  }

  private func saveChanges() {
    let selected = selectedInstrument
    let goalQty = InstrumentAmount.parseQuantity(
      from: savingsGoal, decimals: selected.decimals)
    let goal =
      goalQty.flatMap {
        $0 > 0 ? InstrumentAmount(quantity: $0, instrument: selected) : nil
      }

    var updated = earmark
    updated.name = name
    if supportsComplexTransactions {
      updated.instrument = selected
    }
    updated.savingsGoal = goal
    updated.savingsStartDate = useDateRange ? startDate : nil
    updated.savingsEndDate = useDateRange ? endDate : nil
    updated.isHidden = isHidden

    onUpdate(updated)
  }
}

#Preview("Edit — complex transactions") {
  EditEarmarkSheet(
    earmark: Earmark(
      name: "US Travel",
      instrument: .USD,
      savingsGoal: InstrumentAmount(quantity: 5000, instrument: .USD)
    ),
    supportsComplexTransactions: true,
    onUpdate: { _ in }
  )
}
