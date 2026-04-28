import SwiftUI

struct CreateEarmarkSheet: View {
  let instrument: Instrument
  let onCreate: (Earmark) -> Void

  @State private var name: String = ""
  @State private var currency: Instrument
  @State private var savingsGoal: String = ""
  @State private var startDate = Date()
  @State private var endDate: Date =
    Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
  @State private var useDateRange: Bool = false
  @Environment(\.dismiss) private var dismiss

  init(
    instrument: Instrument,
    onCreate: @escaping (Earmark) -> Void
  ) {
    self.instrument = instrument
    self.onCreate = onCreate
    _currency = State(initialValue: instrument)
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
        InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
      }
      Section("Savings Goal") {
        HStack {
          Text(currency.displayLabel)
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
    .navigationTitle("New Earmark")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") { createEarmark() }
          .disabled(name.isEmpty)
      }
    }
  }

  private func createEarmark() {
    let selected = currency
    let goalQty = InstrumentAmount.parseQuantity(from: savingsGoal, decimals: selected.decimals)
    let goal =
      goalQty.flatMap { $0 > 0 ? InstrumentAmount(quantity: $0, instrument: selected) : nil }

    let newEarmark = Earmark(
      name: name,
      instrument: selected,
      savingsGoal: goal,
      savingsStartDate: useDateRange ? startDate : nil,
      savingsEndDate: useDateRange ? endDate : nil
    )
    onCreate(newEarmark)
  }
}

#Preview("Create Earmark") {
  CreateEarmarkSheet(
    instrument: .AUD,
    onCreate: { _ in }
  )
}
