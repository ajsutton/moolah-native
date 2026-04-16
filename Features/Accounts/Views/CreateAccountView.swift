import SwiftUI

struct CreateAccountView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var type: AccountType = .bank
  @State private var currencyCode: String
  @State private var balanceDecimal: Decimal = 0
  @State private var date = Date()
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @FocusState private var focusedField: Field?

  let instrument: Instrument
  let accountStore: AccountStore
  let supportsComplexTransactions: Bool

  private enum Field: Hashable {
    case name
    case balance
  }

  init(
    instrument: Instrument, accountStore: AccountStore,
    supportsComplexTransactions: Bool = false
  ) {
    self.instrument = instrument
    self.accountStore = accountStore
    self.supportsComplexTransactions = supportsComplexTransactions
    _currencyCode = State(initialValue: instrument.id)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
            .focused($focusedField, equals: .name)
            .onSubmit { focusedField = .balance }
            .accessibilityLabel("Account name")

          Picker("Account Type", selection: $type) {
            ForEach(AccountType.allCases, id: \.self) { type in
              Text(type.displayName).tag(type)
            }
          }

          if supportsComplexTransactions {
            CurrencyPicker(selection: $currencyCode)
          }

          LabeledContent("Initial Balance") {
            TextField(
              "Amount",
              value: $balanceDecimal,
              format: .currency(code: currencyCode)
            )
            .monospacedDigit()
            .focused($focusedField, equals: .balance)
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
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .font(.caption)
          }
        }
      }
      .navigationTitle("Create Account")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      #if os(macOS)
        .defaultFocus($focusedField, .name)
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

    let selectedInstrument =
      supportsComplexTransactions
      ? Instrument.fiat(code: currencyCode) : instrument
    let openingBalance = InstrumentAmount(quantity: balanceDecimal, instrument: selectedInstrument)
    let newAccount = Account(
      id: UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      type: type,
      instrument: selectedInstrument,
      position: 0  // Server will set appropriate position
    )

    do {
      _ = try await accountStore.create(newAccount, openingBalance: openingBalance)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isSubmitting = false
    }
  }
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(repository: backend.accounts, targetInstrument: .AUD)

  CreateAccountView(
    instrument: .AUD, accountStore: accountStore,
    supportsComplexTransactions: true)
}
