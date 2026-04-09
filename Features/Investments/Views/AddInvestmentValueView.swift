import SwiftUI

struct AddInvestmentValueView: View {
  @Environment(\.dismiss) private var dismiss

  let accountId: UUID
  let currency: Currency
  let store: InvestmentStore

  @State private var date = Date()
  @State private var valueString = ""
  @State private var isSubmitting = false

  private var parsedCents: Int? {
    let cleaned = valueString.replacingOccurrences(
      of: "[^0-9.]", with: "", options: .regularExpression)
    guard let decimal = Decimal(string: cleaned) else { return nil }
    let cents = Int(truncating: (decimal * 100) as NSNumber)
    return cents >= 0 ? cents : nil
  }

  private var canSubmit: Bool {
    parsedCents != nil && !isSubmitting
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          DatePicker("Date", selection: $date, displayedComponents: .date)

          HStack {
            Text(currency.code)
              .foregroundStyle(.secondary)
            TextField("Value", text: $valueString)
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
          }
        } header: {
          Text("Investment Value")
        } footer: {
          if let cents = parsedCents {
            Text(
              "Value: \(MonetaryAmount(cents: cents, currency: currency).decimalValue, format: .currency(code: currency.code))"
            )
            .monospacedDigit()
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Add Value")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            Task {
              await submitValue()
            }
          }
          .disabled(!canSubmit)
        }
      }
    }
  }

  private func submitValue() async {
    guard let cents = parsedCents else { return }
    isSubmitting = true

    let amount = MonetaryAmount(cents: cents, currency: currency)
    await store.setValue(accountId: accountId, date: date, value: amount)

    isSubmitting = false
    dismiss()
  }
}
