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
/// - A single status row: a context label (chain name for crypto — the
///   untruncated address already appears above, so no truncated copy is
///   shown here; provider name for exchange) and an inline "open
///   externally" link (block explorer / provider website) on the
///   leading edge, with the last-synced relative timestamp ("Synced 2h
///   ago" / "Never synced") and the "Sync now" button trailing on the
///   *same* line. The button calls `syncStore.syncAccount(account)` and
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

  /// Relative last-synced label for a given clock instant. `now` is
  /// supplied by the enclosing `TimelineView` (see `statusRow`) so the
  /// label ticks on the timeline's cadence rather than being frozen at
  /// the last unrelated re-render. The formatting itself stays in the
  /// unit-tested `SyncedAccountHeaderLogic`.
  private func lastSyncedText(now: Date) -> String {
    SyncedAccountHeaderLogic.lastSyncedText(state: syncState, now: now)
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
      statusRow(presentation)
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

  /// Single-line status row. Leading edge: a context label + the
  /// inline "open externally" link. Trailing edge: the last-synced
  /// timestamp and the "Sync now" button — all on one line, so the
  /// header is a single row for exchange and exactly two for crypto
  /// (the extra row being only the untruncated address).
  ///
  /// For crypto the label is the chain name: the untruncated wallet
  /// address is shown on its own line by `addressSection`, so repeating
  /// a *truncated* copy here would be both redundant and (truncated)
  /// unsafe to verify against. For exchange there is no address line,
  /// so the label is the provider name. `secondaryIdentifier ??
  /// identifier` resolves to the chain for crypto and the provider for
  /// exchange (and degrades to the truncated address only if a crypto
  /// account has no recognised chain) without the view branching on
  /// `account.type` — that branching stays in
  /// `SyncableAccountPresentation`.
  private func statusRow(_ presentation: SyncableAccountPresentation) -> some View {
    HStack(spacing: 12) {
      // The label is its own VoiceOver stop; the external Link stays a
      // separate focusable action rather than being folded into it.
      Text(presentation.secondaryIdentifier ?? presentation.identifier)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.chainName)
      if let url = presentation.externalURL,
        let title = presentation.externalActionTitle
      {
        Link(title, destination: url)
          .font(.caption)
      }
      Spacer(minLength: 12)
      // `context.date` ticks every 60s on the timeline's schedule, so
      // the relative label ("Synced 3 min ago") stays fresh without an
      // unrelated re-render. `.id(context.date)` forces the `Text` to
      // re-evaluate on each tick. Mirrors `SyncProgressFooter`.
      TimelineView(.periodic(from: .now, by: 60)) { context in
        Text(lastSyncedText(now: context.date))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.lastSynced)
          .id(context.date)
      }
      syncButton(presentation)
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
      // Sighted users get the error affordance from the red colour;
      // give VoiceOver the same signal since the message text itself
      // carries no "error" marker.
      .accessibilityLabel("Error: \(caption)")
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
    .buttonStyle(.borderless)
    .help(
      presentation.hasCredential
        ? "Sync account now"
        : (presentation.missingCredentialHint ?? "Configure this account to enable sync")
    )
    .accessibilityLabel(isSyncing ? "Syncing in progress" : "Sync account now")
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
// The parent `CryptoWalletAccountView` / `ExchangeAccountView` previews
// render this header as `EmptyView` (their `ProfileSession.preview()`
// leaves crypto wiring `nil`), so this standalone `#Preview` is the only
// canvas path that exercises the layout. The header reads only
// `SyncedAccountStore`'s observable `statePerAccount` /
// `inProgressAccountIds`, so a minimal store over the in-memory preview
// backend (no sync sources) covers the full layout. No checkpoint is
// seeded, so both rows read "Never synced" — sufficient to verify the
// single-line layout (the timestamp string does not affect the row's
// line count). `hasCredential` resolves `false` in canvas (no
// keychain), so each variant also shows its missing-credential hint
// *below* the status row; that is a real state and does not change
// whether the status row itself is a single line.

#Preview("Synced account header") {
  syncedAccountHeaderPreview()
}

// Builds the standalone-preview content. Extracted from the `#Preview`
// closure so the (unavoidably verbose) store wiring is governed by
// `function_body_length` rather than the stricter `closure_body_length`.
@MainActor
private func syncedAccountHeaderPreview() -> some View {
  // `ProfileSession.preview()` throws only if the in-memory SwiftData
  // container can't be created — a programmer error; crashing is correct.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let store = SyncedAccountStore(
    sources: [],
    walletApplyEngine: WalletApplyEngine(
      transactions: session.backend.transactions,
      walletSyncState: session.backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine()),
    walletSyncState: session.backend.walletSyncState,
    accounts: session.backend.accounts,
    transferDetection: TransferDetectionCoordinator(
      transactions: session.backend.transactions,
      dismissedPairs: session.backend.dismissedTransferPairs),
    transactions: session.backend.transactions)
  let exchangeTokenStore = ExchangeTokenStore()
  let cryptoAccount = Account(
    name: "Preview Wallet",
    type: .crypto,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades,
    walletAddress: "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60",
    chainId: 10)
  let exchangeAccount = Account(
    name: "Coinstash",
    type: .exchange,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades,
    exchangeProvider: .coinstash)
  return VStack(spacing: 24) {
    SyncedAccountHeaderView(
      account: cryptoAccount,
      syncStore: store,
      cryptoTokenStore: nil,
      exchangeTokenStore: exchangeTokenStore)
    SyncedAccountHeaderView(
      account: exchangeAccount,
      syncStore: store,
      cryptoTokenStore: nil,
      exchangeTokenStore: exchangeTokenStore)
  }
  .frame(width: 720)
  .padding()
}
