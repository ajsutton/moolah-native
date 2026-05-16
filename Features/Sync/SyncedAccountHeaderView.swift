// Features/Sync/SyncedAccountHeaderView.swift
import Foundation
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Compact header for a syncable account (`AccountType.crypto` or
/// `.exchange`). All account-type branching lives in
/// `SyncableAccountPresentation` so this view stays provider-agnostic.
/// Renders:
///
/// - For crypto: the full wallet address in a monospaced, selectable
///   font with a copy button. The address is **never** truncated in
///   that section — a truncated `0x1234…abcd` is unsafe to verify
///   against because an attacker can mine a vanity address with
///   matching prefix and suffix.
/// - A presentation identifier row: a truncated copyable address +
///   chain name for crypto, or the (non-copyable) provider name for
///   exchange, plus an inline "open externally" link (block explorer /
///   provider website).
/// - Last-synced relative timestamp ("Synced 2h ago") or "Never synced"
///   when the account has no checkpoint yet.
/// - "Sync now" button that calls `syncStore.syncAccount(account)` and
///   is disabled while a sync is in flight or the account's credential
///   is missing.
///
/// Pure presentation: every piece of business logic that benefits from
/// unit testing (last-synced formatting, sync button state, error
/// caption, credential presence) lives in `SyncedAccountHeaderLogic`.
struct SyncedAccountHeaderView: View {
  let account: Account
  let syncStore: SyncedAccountStore

  /// Token stores used once (in `.task`) to compute `hasCredential`.
  /// Crypto reads the Alchemy key off `CryptoTokenStore`; exchange
  /// reads the per-account token off `ExchangeTokenStore`.
  let cryptoTokenStore: CryptoTokenStore?
  let exchangeTokenStore: ExchangeTokenStore

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

  /// Credential presence (Alchemy key / exchange token). Read once via
  /// `.task(id:)` — never in `body` (the keychain lookup would
  /// otherwise fire on every render/scroll frame). Defaults to `true`
  /// so the header doesn't flash a "missing credential" state before
  /// the task runs, and matches the optimistic-on-keychain-error intent.
  @State private var hasCredential = true

  init(
    account: Account,
    syncStore: SyncedAccountStore,
    cryptoTokenStore: CryptoTokenStore?,
    exchangeTokenStore: ExchangeTokenStore,
    copyToPasteboard: @escaping @MainActor (String) -> Void = SyncedAccountHeaderView.defaultCopy,
    openExternalURL: @escaping @MainActor (URL) -> Void = SyncedAccountHeaderView.defaultOpen
  ) {
    self.account = account
    self.syncStore = syncStore
    self.cryptoTokenStore = cryptoTokenStore
    self.exchangeTokenStore = exchangeTokenStore
    self.copyToPasteboard = copyToPasteboard
    self.openExternalURL = openExternalURL
  }

  private var address: String { account.walletAddress ?? "" }

  private var syncState: WalletSyncState? {
    syncStore.statePerAccount[account.id]
  }

  private var lastSyncedText: String {
    SyncedAccountHeaderLogic.lastSyncedText(state: syncState, now: Date())
  }

  private var isSyncing: Bool {
    syncStore.inProgressAccountIds.contains(account.id)
  }

  /// Per-account error caption (red), or `nil` when the most recent
  /// build phase succeeded.
  private var errorCaption: String? {
    SyncedAccountHeaderLogic.errorCaption(for: syncState, account: account)
  }

  private var presentation: SyncableAccountPresentation {
    SyncableAccountPresentation(account: account, hasCredential: hasCredential)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if account.type == .crypto {
        addressSection
      }
      identifierRow(presentation)
      HStack(spacing: 12) {
        Spacer(minLength: 12)
        Text(lastSyncedText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.lastSynced)
        syncButton(presentation)
      }
      // Status bar below the header showing whichever of (a) the per-
      // account sync error and (b) the missing-credential hint applies.
      // The hint takes precedence: if no credential is configured the
      // user has one fix path and the per-account error is a downstream
      // consequence — surfacing both would just duplicate the prompt.
      if let hint = presentation.missingCredentialHint {
        missingCredentialHint(hint)
      } else if let errorCaption {
        errorCaptionView(errorCaption)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.container)
    .task(id: account.id) {
      hasCredential = SyncedAccountHeaderLogic.hasCredential(
        for: account,
        cryptoTokenStore: cryptoTokenStore,
        exchangeTokenStore: exchangeTokenStore)
    }
  }

  /// Identifier + secondary line + "open externally" link. The whole
  /// row is suppressed for non-syncable account types (presentation
  /// identifier is `""` there) so an empty `Text` doesn't occupy layout.
  @ViewBuilder
  private func identifierRow(_ presentation: SyncableAccountPresentation) -> some View {
    if !presentation.identifier.isEmpty {
      HStack {
        // Identifier + chain name form one VoiceOver stop. Only this
        // text subgroup is combined so the external Link below stays a
        // separate focusable action, and `.textSelection` on the crypto
        // address remains reachable to VoiceOver.
        HStack(spacing: 4) {
          identifierText(presentation)
          if let secondary = presentation.secondaryIdentifier {
            Text(secondary)
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.chainName)
          }
        }
        .accessibilityElement(children: .combine)
        if let url = presentation.externalURL,
          let title = presentation.externalActionTitle
        {
          Link(title, destination: url)
            .font(.caption)
        }
      }
    }
  }

  /// The identifier label. Crypto addresses are copyable
  /// (security-critical — the user must be able to verify them); a
  /// provider name is not. `TextSelectability`'s `.enabled` / `.disabled`
  /// are distinct types, so the two cases are separate `Text` views in a
  /// `@ViewBuilder` (not a ternary on a single `.textSelection`, which
  /// does not type-check).
  @ViewBuilder
  private func identifierText(_ presentation: SyncableAccountPresentation) -> some View {
    if presentation.isSelectableIdentifier {
      Text(presentation.identifier)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    } else {
      Text(presentation.identifier)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.disabled)
    }
  }

  /// Inline prompt rendered when the account's sync credential is
  /// absent. For crypto, pairs the hint with a `SettingsLink` so the
  /// user can jump straight to Crypto preferences; exchange has no
  /// `SettingsLink` (its fix is editing the account, surfaced
  /// elsewhere).
  private func missingCredentialHint(_ hint: String) -> some View {
    HStack(spacing: 6) {
      // Icon + hint text form one VoiceOver stop. The icon is
      // decorative (hidden from VoiceOver); only this subgroup is
      // combined so the macOS `SettingsLink` stays independently
      // activatable.
      HStack(spacing: 6) {
        Image(systemName: "key.slash")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      // `SettingsLink` is macOS-only and crypto-only. iOS users
      // navigate to Crypto preferences from the app's settings tab;
      // the hint copy alone is enough on that platform.
      #if os(macOS)
        if account.type == .crypto {
          SettingsLink {
            Text("Open preferences")
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.missingApiKeyHintLink)
        }
      #endif
      Spacer()
    }
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.missingApiKeyHint)
  }

  /// Inline error caption rendered when `WalletSyncState.lastError`
  /// is non-nil. Red `.caption`.
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

  private func syncButton(_ presentation: SyncableAccountPresentation) -> some View {
    Button {
      Task { await syncStore.syncAccount(account) }
    } label: {
      if isSyncing {
        ProgressView().controlSize(.small)
      } else {
        Label("Sync now", systemImage: "arrow.clockwise")
      }
    }
    .disabled(
      !SyncedAccountHeaderLogic.isSyncEnabled(
        accountId: account.id,
        inProgress: syncStore.inProgressAccountIds,
        hasCredential: presentation.hasCredential)
    )
    .help(
      presentation.hasCredential
        ? "Sync account now"
        : (presentation.missingCredentialHint ?? "Configure this account to enable sync")
    )
    .accessibilityLabel("Sync account now")
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.syncButton)
  }
}

// MARK: - Pasteboard / browser defaults

extension SyncedAccountHeaderView {
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

// MARK: - Previews
//
// `SyncedAccountHeaderView` has no standalone `#Preview`: it requires a
// non-optional `SyncedAccountStore`, which `ProfileSession.preview()`
// leaves `nil` (its crypto wiring is intentionally absent in previews —
// see the `CryptoWalletAccountView` preview comment). The header is
// exercised in canvas through its parents instead — the crypto path via
// `CryptoWalletAccountView`'s `#Preview` and the exchange path via
// `ExchangeAccountView`'s `#Preview`.
