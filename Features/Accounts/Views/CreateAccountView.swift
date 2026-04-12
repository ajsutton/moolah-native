import SwiftUI

struct CreateAccountView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var type: AccountType = .bank
  @State private var balanceDecimal: Decimal = 0
  @State private var date = Date()
  @State private var isSubmitting = false
  @State private var errorMessage: String?

  let instrument: Instrument
  let accountStore: AccountStore

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
            .accessibilityLabel("Account name")

          Picker("Account Type", selection: $type) {
            ForEach(AccountType.allCases, id: \.self) { type in
              Text(type.displayName).tag(type)
            }
          }

          LabeledContent("Initial Balance") {
            TextField(
              "Amount",
              value: $balanceDecimal,
              format: .currency(code: instrument.id)
            )
            #if os(iOS)
              .keyboardType(.decimalPad)
              .multilineTextAlignment(.trailing)
            #endif
            .accessibilityLabel("Initial balance")
          }

          DatePicker("Date", selection: $date, displayedComponents: .date)
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
              .font(.caption)
          }
        }
      }
      .navigationTitle("Create Account")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") { Task { await submit() } }
            .disabled(!isValid || isSubmitting)
        }
      }
    }
  }

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func submit() async {
    guard isValid else { return }

    isSubmitting = true
    errorMessage = nil

    let newAccount = Account(
      id: UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      type: type,
      balance: InstrumentAmount(quantity: balanceDecimal, instrument: instrument),
      position: 0  // Server will set appropriate position
    )

    do {
      _ = try await accountStore.create(newAccount)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isSubmitting = false
    }
  }
}
