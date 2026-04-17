import SwiftUI

struct EditAccountView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var type: AccountType
  @State private var currencyCode: String
  @State private var isHidden: Bool
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @State private var showingHideConfirmation = false
  @State private var displayBalance: InstrumentAmount?
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
    _currencyCode = State(initialValue: account.instrument.id)
    _isHidden = State(initialValue: account.isHidden)
  }

  var body: some View {
    NavigationStack {
      Form {
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
            CurrencyPicker(selection: $currencyCode)
          }

          LabeledContent("Current Balance") {
            if let displayBalance {
              InstrumentAmountView(amount: displayBalance)
                .foregroundStyle(.secondary)
            } else {
              ProgressView()
                .controlSize(.small)
            }
          }
          .accessibilityLabel("Current balance, read-only")
        }

        PositionListView(positions: accountStore.positions(for: account.id))

        Section {
          Toggle("Hide Account", isOn: $isHidden)
            .disabled(!accountStore.canDelete(account.id))
            .accessibilityHint(
              !accountStore.canDelete(account.id)
                ? "Account must have zero balance to hide"
                : ""
            )
        }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .font(.caption)
          }
        }

        Section {
          Button("Hide Account", role: .destructive) {
            showingHideConfirmation = true
          }
          .disabled(!accountStore.canDelete(account.id))
          .accessibilityHint(
            !accountStore.canDelete(account.id)
              ? "Account must have zero balance to hide"
              : ""
          )
        }
      }
      .task(id: balanceInputs) {
        displayBalance = try? await accountStore.displayBalance(for: account.id)
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
        Button("Hide", role: .destructive) {
          Task { await delete() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This account will be hidden. You can show it again later from the View menu.")
      }
    }
  }

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private var balanceInputs: BalanceInputs {
    BalanceInputs(
      positions: accountStore.positions(for: account.id),
      investmentValue: accountStore.investmentValues[account.id]
    )
  }

  private struct BalanceInputs: Equatable {
    let positions: [Position]
    let investmentValue: InstrumentAmount?
  }

  private func save() async {
    guard isValid else { return }

    isSubmitting = true
    errorMessage = nil

    var updated = account
    updated.name = name.trimmingCharacters(in: .whitespaces)
    updated.type = type
    if supportsComplexTransactions {
      updated.instrument = Instrument.fiat(code: currencyCode)
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
