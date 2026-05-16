import Foundation

/// Per-account view data shared by `SyncedAccountHeaderView`. The ONLY
/// place account-type branching is allowed for synced-account UI — the
/// header stays provider-agnostic. `hasCredential` is injected because
/// credential presence (Alchemy key / exchange token) is not derivable
/// from `Account`.
struct SyncableAccountPresentation: Sendable {
  let identifier: String
  /// Secondary line (crypto: chain name, e.g. "Ethereum" — preserves the
  /// context the removed `Text(chain.displayName)` row gave; exchange: nil).
  let secondaryIdentifier: String?
  /// Crypto addresses are copyable (security-critical); a provider name is not.
  let isSelectableIdentifier: Bool
  let externalURL: URL?
  /// `nil` when there is no external action (no empty-string sentinel).
  let externalActionTitle: String?
  /// Non-nil when the account can't sync because its credential is absent.
  let missingCredentialHint: String?
  /// Drives the header's sync-button enabled state for any account kind.
  let hasCredential: Bool

  init(account: Account, hasCredential: Bool) {
    self.hasCredential = hasCredential
    switch account.type {
    case .crypto:
      let addr = account.walletAddress ?? ""
      identifier =
        addr.count > 12
        ? "\(addr.prefix(6))…\(addr.suffix(4))" : addr
      secondaryIdentifier =
        account.chainId
        .flatMap(ChainConfig.config(for:))?.displayName
      isSelectableIdentifier = true
      externalActionTitle = "Open in block explorer"
      if let chainId = account.chainId, !addr.isEmpty {
        // Reuse the existing helper (handles isDirectory:false / trailing
        // slash correctly) instead of hand-building the path.
        externalURL = BlockExplorerLink.addressURL(
          chainId: chainId, address: addr)
      } else {
        externalURL = nil
      }
      // Byte-verbatim with the crypto missing-Alchemy-key hint in
      // `SyncedAccountHeaderView` — do not reword without updating
      // `CryptoSettingsView` too.
      missingCredentialHint =
        hasCredential
        ? nil : "Add an Alchemy key in Crypto preferences to enable sync."
    case .exchange:
      secondaryIdentifier = nil
      isSelectableIdentifier = false
      if let provider = account.exchangeProvider {
        identifier = provider.displayName
        externalActionTitle = "Open \(provider.displayName)"
        externalURL = provider.website
      } else {
        // Defensive: well-formed exchange accounts always have a provider.
        identifier = "Exchange"
        externalActionTitle = nil  // no URL ⇒ no title (no dangling label)
        externalURL = nil
      }
      missingCredentialHint =
        hasCredential
        ? nil : "Edit this account to add a read-only API token."
    case .bank, .creditCard, .asset, .investment:
      identifier = ""
      secondaryIdentifier = nil
      isSelectableIdentifier = false
      externalActionTitle = nil
      externalURL = nil
      missingCredentialHint = nil
    }
  }
}
