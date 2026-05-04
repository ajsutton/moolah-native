import SwiftUI

struct EditAccountView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var type: AccountType
  @State private var currency: Instrument
  @State private var isHidden: Bool
  @State private var valuationMode: ValuationMode
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @FocusState private var focusedField: Field?

  let account: Account
  let accountStore: AccountStore

  private enum Field: Hashable {
    case name
  }

  init(account: Account, accountStore: AccountStore) {
    self.account = account
    self.accountStore = accountStore
    _name = State(initialValue: account.name)
    _type = State(initialValue: account.type)
    _currency = State(initialValue: account.instrument)
    _isHidden = State(initialValue: account.isHidden)
    _valuationMode = State(initialValue: account.valuationMode)
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
      detailsSection
      valuationSection
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.caption)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Edit Account")
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
        Button("Save") { Task { await save() } }
          .disabled(!isValid || isSubmitting)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: type)
  }

  private var detailsSection: some View {
    Section {
      TextField("Name", text: $name, prompt: Text("e.g. Savings Account"))
        .focused($focusedField, equals: .name)
        .accessibilityLabel("Account name")
      Picker("Account Type", selection: $type) {
        ForEach(AccountType.allCases, id: \.self) { type in
          Text(type.displayName).tag(type)
        }
      }
      InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
      Toggle("Hidden", isOn: $isHidden)
        .disabled(!accountStore.canDelete(account.id))
        .accessibilityHint(
          !accountStore.canDelete(account.id)
            ? "Account must have zero balance to hide"
            : "")
    }
  }

  /// Visible only for investment accounts. Lets the user choose between the
  /// snapshot-driven `recordedValue` mode and the position-driven
  /// `calculatedFromTrades` mode. Footer text describes the active mode so
  /// the user can predict what the sidebar balance will read.
  @ViewBuilder private var valuationSection: some View {
    if type == .investment {
      Section {
        Picker("Valuation", selection: $valuationMode) {
          Text("Recorded value").tag(ValuationMode.recordedValue)
          Text("Calculated from trades").tag(ValuationMode.calculatedFromTrades)
        }
        .accessibilityIdentifier("editAccount.valuationMode")
        .accessibilityHint(
          valuationMode == .recordedValue
            ? "Balance comes from the value you last recorded"
            : "Balance is calculated from your trade history and current prices of your holdings"
        )
      } footer: {
        Text(
          valuationMode == .recordedValue
            ? "The balance comes from the value you last recorded manually."
            : "The balance is calculated from your trade history and the current prices "
              + "of your holdings.")
      }
    }
  }

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func save() async {
    guard isValid else { return }

    isSubmitting = true
    errorMessage = nil

    var updated = account
    updated.name = name.trimmingCharacters(in: .whitespaces)
    updated.type = type
    updated.instrument = currency
    updated.isHidden = isHidden
    updated.valuationMode = valuationMode

    do {
      _ = try await accountStore.update(updated)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isSubmitting = false
    }
  }
}

#Preview("Bank account") {
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)

  EditAccountView(
    account: Account(name: "Checking", type: .bank, instrument: .AUD),
    accountStore: accountStore)
}

#Preview("Investment account") {
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)

  EditAccountView(
    account: Account(
      name: "Brokerage",
      type: .investment,
      instrument: .AUD,
      valuationMode: .calculatedFromTrades),
    accountStore: accountStore)
}
