// Features/Crypto/CryptoAccountCreationView.swift
import Foundation
import SwiftUI

/// Form fields for creating a new `AccountType.crypto` account.
///
/// Renders the crypto-specific portion of the account-creation sheet:
/// chain picker (ETH / OP / Base / Polygon) and a wallet-address text
/// field. Per the design spec, the account's `instrument` is set
/// automatically to the chain's native instrument (ETH for
/// Ethereum/OP/Base, MATIC for Polygon); per-token positions emerge
/// from leg aggregation as wallet syncs land.
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
/// / toolbar. This view exposes:
///
/// - `body` — the chain picker and address field (rendered inside the
///   parent `Form`).
/// - `CryptoAccountCreationLogic` — pure form-logic type used by the
///   parent's Save button to validate and submit; kept separate so
///   `CryptoAccountCreationLogicTests` exercise the contract directly
///   without spinning up a SwiftUI view.
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

// MARK: - Submit logic

/// Pure form-logic helper for the crypto branch of `CreateAccountView`.
/// Owns the create-account + kick-off-sync sequence so the parent view
/// can dispatch from its Save button without relying on a transient
/// SwiftUI view instance, and so `CryptoAccountCreationLogicTests` can
/// exercise the contract end-to-end against `TestBackend`.
@MainActor
struct CryptoAccountCreationLogic {
  let accountStore: AccountStore
  /// May be `nil` in degraded launches (preview / no instrument
  /// registry). When `nil`, account creation still proceeds; the first
  /// sync simply isn't kicked off — the next scenePhase `.active`
  /// stale-check will pick it up.
  let cryptoSyncStore: CryptoSyncStore?

  /// Output of `submit(name:chain:walletAddressInput:)`. The parent
  /// surface uses `.created` to dismiss the sheet and `.failure` /
  /// `.invalidAddress` to show an inline error message.
  enum Outcome: Sendable {
    case created(Account)
    case invalidAddress
    case failure(Error)
  }

  /// Persists the new crypto account and kicks off its first sync.
  /// Returns the outcome rather than mutating shared state directly so
  /// the parent view can decide how to surface success vs failure.
  func submit(name: String, chain: ChainConfig, walletAddressInput: String) async -> Outcome {
    guard let walletAddress = Account.validatedWalletAddress(walletAddressInput) else {
      return .invalidAddress
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return .invalidAddress }

    let account = Account(
      name: trimmedName,
      type: .crypto,
      instrument: chain.nativeInstrument,
      walletAddress: walletAddress,
      chainId: chain.chainId
    )

    do {
      let created = try await accountStore.create(account)
      // Kick off the initial sync so the wallet's history starts
      // loading immediately. The store internally guards against
      // duplicate in-flight syncs, so the next scenePhase `.active`
      // trigger collapses with this dispatch rather than queueing a
      // redundant pass. A `nil` `cryptoSyncStore` (degraded launch)
      // leaves the account stale; the next stale-sync pass picks it
      // up.
      if let cryptoSyncStore {
        await cryptoSyncStore.syncAccount(created)
      }
      return .created(created)
    } catch {
      return .failure(error)
    }
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
