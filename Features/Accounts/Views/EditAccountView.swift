import SwiftUI

struct EditAccountView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var type: AccountType
  @State private var currency: Instrument
  @State private var isHidden: Bool
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @State private var showingHideConfirmation = false
  @FocusState private var focusedField: Field?

  let account: Account
  let accountStore: AccountStore
  let supportsComplexTransactions: Bool

  private enum Field: Hashable {
    case name
  }

  init(account: Account, accountStore: AccountStore, supportsComplexTransactions: Bool = false) {
    self.account = account
    self.accountStore = accountStore
    self.supportsComplexTransactions = supportsComplexTransactions
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
      hideToggleSection
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.caption)
        }
      }
      hideActionSection
    }
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
    .confirmationDialog(
      "Hide Account",
      isPresented: $showingHideConfirmation,
      titleVisibility: .visible
    ) {
      Button("Hide", role: .destructive) { Task { await delete() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This account will be hidden. You can show it again later from the View menu.")
    }
  }

  private var detailsSection: some View {
    Section {
      TextField("Name", text: $name)
        .focused($focusedField, equals: .name)
        .accessibilityLabel("Account name")
      Picker("Account Type", selection: $type) {
        ForEach(AccountType.allCases, id: \.self) { type in
          Text(type.displayName).tag(type)
        }
      }
      if supportsComplexTransactions {
        CurrencyPicker(selection: $currency)
      }
      LabeledContent("Current Balance") {
        currentBalanceDisplay
      }
      .accessibilityLabel("Current balance, read-only")
      .accessibilityValue(balanceAccessibilityValue)
    }
  }

  @ViewBuilder private var currentBalanceDisplay: some View {
    if let displayBalance {
      InstrumentAmountView(amount: displayBalance)
        .foregroundStyle(.secondary)
    } else if isBalanceUnavailable {
      Text("Unavailable")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Current balance unavailable")
    } else {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Loading balance")
    }
  }

  private var hideToggleSection: some View {
    Section {
      Toggle("Hide Account", isOn: $isHidden)
        .disabled(!accountStore.canDelete(account.id))
        .accessibilityHint(
          !accountStore.canDelete(account.id)
            ? "Account must have zero balance to hide"
            : "")
    }
  }

  private var hideActionSection: some View {
    Section {
      Button("Hide Account", role: .destructive) {
        showingHideConfirmation = true
      }
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

  /// Reads the converted balance published by `AccountStore`, which handles
  /// retries and logging for conversion failures. `nil` means either no
  /// conversion pass has run yet (loading) or the conversion failed
  /// (unavailable) — `isBalanceUnavailable` distinguishes the two.
  private var displayBalance: InstrumentAmount? {
    accountStore.convertedBalances[account.id]
  }

  /// True when a conversion attempt has completed but no balance is
  /// available — i.e. conversion failed. Distinct from the initial
  /// "still loading" state before the first attempt.
  private var isBalanceUnavailable: Bool {
    accountStore.hasCompletedInitialConversion && displayBalance == nil
  }

  private var balanceAccessibilityValue: String {
    if let displayBalance {
      return displayBalance.formatted
    }
    return isBalanceUnavailable ? "Unavailable" : "Loading"
  }

  private func save() async {
    guard isValid else { return }

    isSubmitting = true
    errorMessage = nil

    var updated = account
    updated.name = name.trimmingCharacters(in: .whitespaces)
    updated.type = type
    if supportsComplexTransactions {
      updated.instrument = currency
    }
    updated.isHidden = isHidden

    do {
      _ = try await accountStore.update(updated)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isSubmitting = false
    }
  }

  private func delete() async {
    isSubmitting = true
    errorMessage = nil

    do {
      try await accountStore.delete(id: account.id)
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
    accountStore: accountStore,
    supportsComplexTransactions: true)
}
