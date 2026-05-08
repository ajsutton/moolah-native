import Foundation

extension UITestIdentifiers {
  /// Identifier namespace for `WalletAccountHeaderView` — the bar that
  /// renders above the transaction list on a `.crypto` account. Lives
  /// in its own file (rather than alongside the rest of
  /// `UITestIdentifiers`) so the parent file stays under SwiftLint's
  /// `file_length` threshold.
  public enum WalletAccountHeader {
    /// Container of the `WalletAccountHeaderView` bar shown above the
    /// transaction list on a `.crypto` account. Sentinel for "the
    /// wallet header is on screen".
    public static let container = "wallet.header.container"

    /// Full wallet-address label. Crypto addresses are never truncated
    /// in the UI — verifying the entire string is what protects the
    /// user from vanity-mined lookalike addresses, so prefix/suffix
    /// abbreviation is unsafe even when it would fit better.
    public static let address = "wallet.header.address"

    /// Copy-address button. Tapping copies the full lowercased
    /// wallet address to the system pasteboard.
    public static let copyAddressButton = "wallet.header.copyAddress"

    /// Chain display-name label (e.g. "Ethereum").
    public static let chainName = "wallet.header.chain"

    /// Last-synced relative-time label (e.g. "Synced 2h ago" or
    /// "Never synced").
    public static let lastSynced = "wallet.header.lastSynced"

    /// "Sync now" button. Disabled while the account is in-flight or
    /// when no Alchemy API key is configured.
    public static let syncButton = "wallet.header.syncNow"

    /// Inline error caption shown when the most recent sync attempt
    /// failed (`WalletSyncState.lastError != nil`).
    public static let errorCaption = "wallet.header.errorCaption"

    /// Inline hint container shown when no Alchemy API key is
    /// configured. Sentinel for "the wallet header is in
    /// disabled-because-no-key mode".
    public static let missingApiKeyHint = "wallet.header.missingApiKeyHint"

    /// `SettingsLink` inside the missing-API-key hint that opens the
    /// Crypto preferences pane.
    public static let missingApiKeyHintLink = "wallet.header.missingApiKeyHint.link"

    /// Overflow menu button (ellipsis). Holds the
    /// "View on block explorer" action.
    public static let overflowMenu = "wallet.header.overflowMenu"
  }
}
