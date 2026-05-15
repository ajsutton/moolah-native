// Features/Crypto/WalletAccountHeaderView.swift
import Foundation
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Compact header for an `AccountType.crypto` account view. Renders:
///
/// - Full wallet address rendered in a monospaced, selectable font with a
///   copy button alongside. The address is **never** truncated — a
///   truncated `0x1234…abcd` is unsafe to verify against because an
///   attacker can mine a vanity address with matching prefix and suffix.
/// - Chain display name (e.g. "Ethereum").
/// - Last-synced relative timestamp ("Synced 2h ago") or "Never synced"
///   when the account has no checkpoint yet.
/// - "Sync now" button that calls `cryptoSyncStore.syncAccount(account)`
///   and is disabled while a sync is in flight for this account.
/// - Overflow menu with "View on block explorer" → opens the chain's
///   address URL in the user's default browser.
///
/// Pure presentation: every piece of business logic that benefits from
/// unit testing (last-synced formatting, sync button state) lives in
/// `WalletAccountHeaderLogic` so `WalletAccountHeaderViewLogicTests` can
/// exercise the contract without spinning up a SwiftUI view.
struct WalletAccountHeaderView: View {
  let account: Account
  let chain: ChainConfig
  let cryptoSyncStore: CryptoSyncStore

  /// Whether the profile has an Alchemy API key configured. Drives
  /// the `Sync now` enabled state and the inline "add a key" hint.
  /// Read by the parent view (`ContentView`) from
  /// `session.cryptoTokenStore?.hasAlchemyApiKey` because the keychain
  /// lookup lives on `CryptoTokenStore`, not on `CryptoSyncStore` —
  /// surfacing it here as a value keeps the header view trivially
  /// previewable + testable without dragging the token store along.
  let hasApiKey: Bool

  /// Closure used to copy the supplied string to the system pasteboard.
  /// Defaulted to the platform's standard pasteboard so production code
  /// has a single sensible default; tests / previews override.
  /// `@MainActor` because the production defaults call `NSPasteboard` /
  /// `UIPasteboard`, both of which are main-actor-isolated.
  let copyToPasteboard: @MainActor (String) -> Void

  /// Closure used to open a URL in the user's default browser.
  /// Defaulted to the platform-standard handler; tests override.
  /// `@MainActor` for the same reason as `copyToPasteboard`.
  let openExternalURL: @MainActor (URL) -> Void

  init(
    account: Account,
    chain: ChainConfig,
    cryptoSyncStore: CryptoSyncStore,
    hasApiKey: Bool,
    copyToPasteboard: @escaping @MainActor (String) -> Void = WalletAccountHeaderView.defaultCopy,
    openExternalURL: @escaping @MainActor (URL) -> Void = WalletAccountHeaderView.defaultOpen
  ) {
    self.account = account
    self.chain = chain
    self.cryptoSyncStore = cryptoSyncStore
    self.hasApiKey = hasApiKey
    self.copyToPasteboard = copyToPasteboard
    self.openExternalURL = openExternalURL
  }

  private var address: String { account.walletAddress ?? "" }

  private var syncState: WalletSyncState? {
    cryptoSyncStore.statePerAccount[account.id]
  }

  private var lastSyncedText: String {
    WalletAccountHeaderLogic.lastSyncedText(state: syncState, now: Date())
  }

  private var isSyncing: Bool {
    cryptoSyncStore.inProgressAccountIds.contains(account.id)
  }

  /// Per-account error caption (red), or `nil` when the most recent
  /// build phase succeeded.
  private var errorCaption: String? {
    WalletAccountHeaderLogic.errorCaption(for: syncState)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      addressSection
      HStack(spacing: 12) {
        Text(chain.displayName)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.chainName)
        Spacer(minLength: 12)
        Text(lastSyncedText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.lastSynced)
        syncButton
        overflowMenu
      }
      // Status bar below the header showing whichever of (a) the per-
      // account sync error and (b) the missing-key hint applies. The
      // missing-key hint takes precedence: if no key is configured the
      // user has one fix path (open preferences) and the per-account
      // error is a downstream consequence — surfacing both would just
      // duplicate the prompt.
      if !hasApiKey {
        missingApiKeyHint
      } else if let errorCaption {
        errorCaptionView(errorCaption)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.container)
  }

  /// Inline prompt rendered when no Alchemy API key is configured.
  /// Pairs the explanation with a `SettingsLink` so the user can jump
  /// straight to Crypto preferences. Uses `SettingsLink` (not a custom
  /// button) so the link respects the platform's settings-pane
  /// activation contract — on macOS that surfaces the Settings window
  /// pre-selected to whatever pane the user was last on, which is
  /// fine: the Crypto tab is the first row in the settings sidebar.
  private var missingApiKeyHint: some View {
    HStack(spacing: 6) {
      Image(systemName: "key.slash")
        .foregroundStyle(.secondary)
      Text("Add an Alchemy key in Crypto preferences to enable sync.")
        .font(.caption)
        .foregroundStyle(.secondary)
      // `SettingsLink` is macOS-only. iOS users navigate to Crypto
      // preferences from the app's settings tab; the hint copy alone
      // is enough on that platform — no inline link.
      #if os(macOS)
        SettingsLink {
          Text("Open preferences")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.missingApiKeyHintLink)
      #endif
      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.missingApiKeyHint)
  }

  /// Inline error caption rendered when `WalletSyncState.lastError`
  /// is non-nil. Red `.caption` matches the same role on
  /// `CryptoAccountsListSection` so users see consistent treatment of
  /// the same underlying error in both surfaces.
  private func errorCaptionView(_ caption: String) -> some View {
    Text(caption)
      .font(.caption)
      .foregroundStyle(.red)
      .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.errorCaption)
  }

  private var addressSection: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(address)
        .font(.body.monospaced())
        .textSelection(.enabled)
        .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.address)
        .accessibilityLabel("Wallet address \(address)")
      Button {
        copyToPasteboard(address)
      } label: {
        Label("Copy address", systemImage: "doc.on.doc")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .help("Copy full wallet address")
      .accessibilityLabel("Copy wallet address")
      .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.copyAddressButton)
      .disabled(address.isEmpty)
      Spacer(minLength: 0)
    }
  }

  private var syncButton: some View {
    Button {
      Task { await cryptoSyncStore.syncAccount(account) }
    } label: {
      if isSyncing {
        ProgressView().controlSize(.small)
      } else {
        Label("Sync now", systemImage: "arrow.clockwise")
      }
    }
    .disabled(
      !WalletAccountHeaderLogic.isSyncEnabled(
        accountId: account.id,
        inProgress: cryptoSyncStore.inProgressAccountIds,
        hasApiKey: hasApiKey)
    )
    .help(hasApiKey ? "Sync wallet now" : "Add an Alchemy API key to enable sync")
    .accessibilityLabel("Sync wallet now")
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.syncButton)
  }

  private var overflowMenu: some View {
    Menu {
      Button {
        guard
          let chainId = account.chainId,
          let url = BlockExplorerLink.addressURL(chainId: chainId, address: address)
        else { return }
        openExternalURL(url)
      } label: {
        Label("View on block explorer", systemImage: "arrow.up.right.square")
      }
      .disabled(account.chainId == nil || address.isEmpty)
    } label: {
      Label("More", systemImage: "ellipsis.circle")
        .labelStyle(.iconOnly)
    }
    .menuStyle(.borderlessButton)
    .help("More wallet actions")
    .accessibilityLabel("More wallet actions")
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.overflowMenu)
  }
}

// MARK: - Pasteboard / browser defaults

extension WalletAccountHeaderView {
  /// Platform-default clipboard write. Lives on the view so tests can
  /// substitute a recording closure via the initialiser without touching
  /// the system pasteboard.
  static func defaultCopy(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }

  /// Platform-default URL opener. Lives on the view so tests can
  /// substitute a recording closure without spawning a real browser.
  static func defaultOpen(_ url: URL) {
    #if os(macOS)
      NSWorkspace.shared.open(url)
    #else
      UIApplication.shared.open(url)
    #endif
  }
}

// MARK: - Pure logic

/// Pure-logic helper for `WalletAccountHeaderView`. Owns the relative-
/// time formatting for the last-synced label, the "is sync allowed"
/// predicate, and the user-facing error caption so they are all
/// unit-testable without instantiating a SwiftUI view.
enum WalletAccountHeaderLogic {
  /// User-facing relative-time label for the wallet's last successful
  /// sync. A `nil` state — or a state whose checkpoint is still the
  /// `.distantPast` sentinel that `persistError` writes for an account
  /// that has never had a successful sync — renders as "Never synced".
  /// Otherwise uses `RelativeDateTimeFormatter.short` and prefixes
  /// "Synced ".
  static func lastSyncedText(state: WalletSyncState?, now: Date) -> String {
    guard let lastSyncedAt = state?.lastSyncedAt, lastSyncedAt != .distantPast else {
      return "Never synced"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let relative = formatter.localizedString(for: lastSyncedAt, relativeTo: now)
    return "Synced \(relative)"
  }

  /// Whether the "Sync now" button should be enabled for the given
  /// account. The button collapses to disabled when:
  ///
  /// - The account is already mid-sync (mirrors
  ///   `CryptoSyncStore.syncAccount`'s collapse-duplicates guard so a
  ///   tap during sync isn't a misleading no-op).
  /// - No Alchemy API key is configured. Per design — "Without a valid
  ///   key, sync is disabled with an inline prompt to add one." — the
  ///   button must visibly refuse so the user is steered to the
  ///   preferences pane instead of staring at a `.missingApiKey`
  ///   error caption every time they tap.
  static func isSyncEnabled(
    accountId: UUID,
    inProgress: Set<UUID>,
    hasApiKey: Bool
  ) -> Bool {
    guard hasApiKey else { return false }
    return !inProgress.contains(accountId)
  }

  /// User-facing string for a `WalletSyncError` persisted on a per-
  /// account `WalletSyncState`. Returns `nil` when the state has no
  /// error so callers can skip rendering the caption row entirely.
  /// Mirrors `CryptoAccountsListSection`'s settings-pane copy so a user
  /// who looks at both surfaces sees consistent language for the same
  /// underlying failure.
  static func errorCaption(for state: WalletSyncState?) -> String? {
    guard let error = state?.lastError else { return nil }
    return errorCaption(for: error)
  }

  /// Branchless variant on the raw error so unit tests can pin the
  /// message for each case without constructing a `WalletSyncState`.
  static func errorCaption(for error: WalletSyncError) -> String {
    switch error {
    case .missingApiKey:
      return "Add an Alchemy API key to enable sync."
    case .invalidApiKey:
      return "Alchemy rejected the API key."
    case .rateLimited(let retryAfter):
      if let retryAfter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return
          "Rate-limited. Retry \(formatter.localizedString(for: retryAfter, relativeTo: Date()))."
      }
      return "Rate-limited. Retry shortly."
    case .network(let underlying):
      return "Network error: \(underlying)"
    case .providerMalformedResponse(let stage):
      return "Provider returned a malformed response (\(stage))."
    }
  }
}
