import SwiftUI

struct EditAccountView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var type: AccountType
  @State private var currency: Instrument
  @State private var isHidden: Bool
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

    do {
      _ = try await accountStore.update(updated)
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

  EditAccountView(
    account: Account(name: "Checking", type: .bank, instrument: .AUD),
    accountStore: accountStore)
}
