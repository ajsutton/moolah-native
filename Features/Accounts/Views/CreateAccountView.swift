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

  // MARK: - Crypto-only form state
  //
  // Held at this level so the shared shell (Cancel + Save toolbar) and
  // the shared name + type Picker keep one set of bindings regardless of
  // which type is currently selected. Switching from `.crypto` back to
  // `.bank` simply hides these fields; the values are preserved so the
  // user can flip back without retyping.

  @State private var cryptoChain: ChainConfig = .ethereum
  @State private var cryptoWalletAddress = ""

  let instrument: Instrument
  let accountStore: AccountStore
  let cryptoSyncStore: CryptoSyncStore?

  private enum Field: Hashable {
    case name
    case balance
    case walletAddress
  }

  init(
    instrument: Instrument,
    accountStore: AccountStore,
    cryptoSyncStore: CryptoSyncStore? = nil
  ) {
    self.instrument = instrument
    self.accountStore = accountStore
    self.cryptoSyncStore = cryptoSyncStore
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
        sharedFields
        if type == .crypto {
          cryptoFields
        } else {
          standardFields
        }
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

  // Shared name + type picker. The crypto branch reuses both, so they
  // live above the type-specific fork.
  @ViewBuilder private var sharedFields: some View {
    TextField("Name", text: $name, prompt: Text(namePrompt))
      .focused($focusedField, equals: .name)
      .onSubmit { focusedField = type == .crypto ? .walletAddress : .balance }
      .accessibilityLabel("Account name")

    Picker("Account Type", selection: $type) {
      ForEach(AccountType.allCases, id: \.self) { type in
        Text(type.displayName).tag(type)
      }
    }
  }

  @ViewBuilder private var standardFields: some View {
    InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)

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

  @ViewBuilder private var cryptoFields: some View {
    CryptoAccountCreationView(
      chain: $cryptoChain,
      walletAddressInput: $cryptoWalletAddress)
  }

  private var namePrompt: String {
    switch type {
    case .crypto: return "e.g. Hardware Wallet — Ethereum"
    default: return "e.g. MyBank - Savings"
    }
  }

  private var isValid: Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty else { return false }
    if type == .crypto {
      return Account.validatedWalletAddress(cryptoWalletAddress) != nil
    }
    return true
  }

  private func submit() async {
    guard isValid else { return }

    isSubmitting = true
    errorMessage = nil

    if type == .crypto {
      await submitCrypto()
      isSubmitting = false
      return
    }

    let selectedInstrument = currency
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

  private func submitCrypto() async {
    let logic = CryptoAccountCreationLogic(
      accountStore: accountStore, cryptoSyncStore: cryptoSyncStore)
    let outcome = await logic.submit(
      name: name, chain: cryptoChain, walletAddressInput: cryptoWalletAddress)
    switch outcome {
    case .created:
      dismiss()
    case .invalidAddress:
      errorMessage = "Enter a valid 0x wallet address."
    case .failure(let error):
      errorMessage = error.localizedDescription
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
    instrument: .AUD, accountStore: accountStore)
}
