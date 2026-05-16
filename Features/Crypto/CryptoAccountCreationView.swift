// Features/Crypto/CryptoAccountCreationView.swift
import Foundation
import SwiftUI

/// Form fields for creating a new `AccountType.crypto` account.
///
/// Renders the crypto-specific portion of the account-creation sheet:
/// chain picker (ETH / OP / Base / Polygon) and a wallet-address text
/// field. The account is denominated in the profile currency (not the
/// chain's native token); per-token positions emerge from leg
/// aggregation, converted into the profile currency as wallet syncs
/// land. The selected chain still drives `chainId` — i.e. which network
/// the wallet sync queries.
///
/// Address validation:
///
/// - Trim whitespace; lowercase the result.
/// - Accept anything matching `^0x[a-f0-9]{40}$` (canonical lowercase
///   form). Mixed-case checksum input is tolerated and normalised down
///   to lowercase.
/// - Pasting an ENS name (`vitalik.eth`) shows the "ENS not supported"
///   inline hint — v1 cannot resolve ENS to a 0x address.
///
/// The shared shell in `CreateAccountView` owns the Form / NavigationStack
/// / toolbar. This view renders only `body` — the chain picker and
/// address field inside the parent `Form`. The validate-and-submit
/// contract lives in `CryptoAccountCreationLogic` (its own file) so
/// `CryptoAccountCreationStoreTests` can exercise it without spinning up
/// a SwiftUI view.
struct CryptoAccountCreationView: View {
  @Binding var chain: ChainConfig
  @Binding var walletAddressInput: String

  var body: some View {
    Picker("Chain", selection: $chain) {
      ForEach(ChainConfig.all, id: \.chainId) { config in
        Text(config.displayName).tag(config)
      }
    }
    .accessibilityIdentifier(UITestIdentifiers.CryptoAccountCreation.chainPicker)

    TextField(
      "Wallet Address",
      text: $walletAddressInput,
      prompt: Text("0x…")
    )
    #if os(iOS)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled(true)
    #endif
    .accessibilityLabel("Wallet address")
    .accessibilityIdentifier(UITestIdentifiers.CryptoAccountCreation.walletAddressField)

    if let hint = Self.inlineAddressHint(for: walletAddressInput) {
      Label(hint, systemImage: "info.circle")
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }

  /// Inline hint shown beneath the address field when the user has
  /// typed something that looks like an ENS name. v1 doesn't resolve
  /// ENS — point the user at the underlying 0x address. `nonisolated`
  /// so unit tests can call it directly without bouncing through the
  /// `@MainActor` `View` protocol.
  nonisolated static func inlineAddressHint(for raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.lowercased().hasPrefix("0x") { return nil }
    if trimmed.contains(".") {
      return "ENS resolution not supported in v1 — paste a 0x address."
    }
    return nil
  }
}

// MARK: - Address validation

extension Account {
  /// Validates an EVM-style wallet address. Accepts the canonical
  /// lowercase form and mixed-case checksum form; rejects anything
  /// else (too short, missing `0x` prefix, ENS names, empty). Returns
  /// the canonical lowercased form on success so callers can persist a
  /// single normalised representation; returns `nil` otherwise.
  ///
  /// Trimming surrounding whitespace is part of the contract — paste
  /// flows commonly include a trailing newline from the source string.
  static func validatedWalletAddress(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.count == 42, trimmed.hasPrefix("0x") else { return nil }
    let suffix = trimmed.dropFirst(2)
    let isHex = suffix.allSatisfy { character in
      character.isASCII
        && (character.isNumber
          || ("a"..."f").contains(character))
    }
    return isHex ? trimmed : nil
  }
}

#Preview {
  @Previewable @State var chain: ChainConfig = .ethereum
  @Previewable @State var address = ""

  Form {
    CryptoAccountCreationView(
      chain: $chain,
      walletAddressInput: $address)
  }
  .formStyle(.grouped)
  .frame(width: 500, height: 320)
}
