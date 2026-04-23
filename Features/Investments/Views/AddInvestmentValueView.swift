import SwiftUI

struct AddInvestmentValueView: View {
  @Environment(\.dismiss) private var dismiss

  let accountId: UUID
  let instrument: Instrument
  let store: InvestmentStore

  @State private var date = Date()
  @State private var valueString = ""
  @State private var isSubmitting = false
  @FocusState private var isValueFieldFocused: Bool

  private var parsedQuantity: Decimal? {
    InstrumentAmount.parseQuantity(from: valueString, decimals: instrument.decimals)
  }

  private var canSubmit: Bool {
    parsedQuantity != nil && !isSubmitting
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
      Section {
        DatePicker("Date", selection: $date, displayedComponents: .date)
        HStack {
          Text(instrument.displayLabel).foregroundStyle(.secondary)
          TextField("Value", text: $valueString)
            .focused($isValueFieldFocused)
            .monospacedDigit()
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif
        }
      } header: {
        Text("Investment Value")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Add Value")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onAppear { isValueFieldFocused = true }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Add") { Task { await submitValue() } }
          .disabled(!canSubmit)
      }
    }
  }

  private func submitValue() async {
    guard let qty = parsedQuantity else { return }
    isSubmitting = true

    let amount = InstrumentAmount(quantity: qty, instrument: instrument)
    await store.setValue(accountId: accountId, date: date, value: amount)

    isSubmitting = false
    dismiss()
  }
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let store = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService
  )
  AddInvestmentValueView(
    accountId: UUID(),
    instrument: .AUD,
    store: store
  )
}
