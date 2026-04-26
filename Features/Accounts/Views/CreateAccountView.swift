// swiftlint:disable multiline_arguments

import SwiftUI

struct CreateAccountView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var type: AccountType = .bank
  @State private var currency: Instrument
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
    instrument: Instrument,
    accountStore: AccountStore,
    supportsComplexTransactions: Bool = false
  ) {
    self.instrument = instrument
    self.accountStore = accountStore
    self.supportsComplexTransactions = supportsComplexTransactions
    _currency = State(initialValue: instrument)
  }

  var body: some View {
    NavigationStack {
      form
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 400)
    #endif
  }

  private var form: some View {
    Form {
      Section {
        detailsFields
      }
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.caption)
        }
      }
    }
    .formStyle(.grouped)
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

  @ViewBuilder private var detailsFields: some View {
    TextField("Name", text: $name, prompt: Text("e.g. MyBank - Savings"))
      .focused($focusedField, equals: .name)
      .onSubmit { focusedField = .balance }
      .accessibilityLabel("Account name")

    Picker("Account Type", selection: $type) {
      ForEach(AccountType.allCases, id: \.self) { type in
        Text(type.displayName).tag(type)
      }
    }

    if supportsComplexTransactions {
      InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
    }

    TextField(
      "Initial Balance", value: $balanceDecimal,
      format: .number.precision(.fractionLength(currency.decimals))
    )
    .monospacedDigit()
    .focused($focusedField, equals: .balance)
    #if os(iOS)
      .keyboardType(.decimalPad)
      .multilineTextAlignment(.trailing)
    #endif
    .accessibilityLabel("Initial balance")

    DatePicker("Opening Date", selection: $date, displayedComponents: .date)
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
      ? currency : instrument
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
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)

  CreateAccountView(
    instrument: .AUD, accountStore: accountStore,
    supportsComplexTransactions: true)
}
