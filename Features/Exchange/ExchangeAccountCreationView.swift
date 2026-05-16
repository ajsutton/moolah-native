// Features/Exchange/ExchangeAccountCreationView.swift
import SwiftUI

/// Form fields for creating a new `AccountType.exchange` account.
///
/// Renders only the exchange-specific portion of the account-creation
/// sheet: provider picker, read-only API-token `SecureField`, and a
/// provider-derived help `Link`. The shared shell in `CreateAccountView`
/// owns the Form / NavigationStack / toolbar and the shared name + type
/// Picker; the validate-store-and-submit contract lives in
/// `ExchangeAccountCreationLogic` (its own file), invoked by
/// `CreateAccountView.submitExchange()`.
///
/// The view holds no `logic` / `onResult` / `name` — a SwiftUI value type
/// can't expose submission agency, and dead params would be an API lie.
struct ExchangeAccountCreationView: View {
  @Binding var provider: ExchangeProvider  // owned by CreateAccountView
  @Binding var token: String  // owned by CreateAccountView

  var body: some View {
    Section {
      Picker("Exchange", selection: $provider) {
        ForEach(ExchangeProvider.allCases, id: \.self) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      .accessibilityIdentifier(
        UITestIdentifiers.ExchangeAccountCreation.providerPicker)
      // Plain SecureField (NOT wrapped in LabeledContent — that
      // double-labels on macOS grouped Form). First arg is the row
      // label; `prompt:` is the placeholder. Matches every other
      // SecureField in the codebase.
      SecureField(
        "API Token",
        text: $token,
        prompt: Text("Paste your read-only token")
      )
      .textContentType(.password)
      .accessibilityLabel("API Token")
      .accessibilityIdentifier(
        UITestIdentifiers.ExchangeAccountCreation.accessTokenField)
      Link(
        "How to create your \(provider.displayName) API key",
        destination: provider.helpURL
      )
      .font(.caption)
      .frame(minHeight: 44)  // ≥44pt hit target
    } footer: {
      // Provider-neutral: the help Link already points at the exact
      // article, so don't bake one provider's UI path into copy shown
      // for every provider. Lead with the user's real concern (safety).
      Text(
        "Moolah only ever reads your transaction history. "
          + "A read-only token keeps your funds safe — it can't trade or withdraw.")
    }
  }
}

#Preview {
  // @Previewable @State for live interactivity (typing into the token
  // field, changing the picker) — matches CryptoAccountCreationView.
  @Previewable @State var provider: ExchangeProvider = .coinstash
  @Previewable @State var token = ""
  Form {
    ExchangeAccountCreationView(provider: $provider, token: $token)
  }
  .formStyle(.grouped)
  #if os(macOS)
    .frame(width: 500, height: 320)
  #endif
}
