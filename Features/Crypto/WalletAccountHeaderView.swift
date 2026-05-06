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
/// - Truncated wallet address (`0xabcd…wxyz`) rendered in a monospaced font
///   with a copy button alongside.
/// - Chain display name (e.g. "Ethereum").
/// - Last-synced relative timestamp ("Synced 2h ago") or "Never synced"
///   when the account has no checkpoint yet.
/// - "Sync now" button that calls `cryptoSyncStore.syncAccount(account)`
///   and is disabled while a sync is in flight for this account.
/// - Overflow menu with "View on block explorer" → opens the chain's
///   address URL in the user's default browser.
///
/// Pure presentation: every piece of business logic that benefits from
/// unit testing (truncation, last-synced formatting, sync button state)
/// lives in `WalletAccountHeaderLogic` so
/// `WalletAccountHeaderViewLogicTests` can exercise the contract without
/// spinning up a SwiftUI view.
struct WalletAccountHeaderView: View {
  let account: Account
  let chain: ChainConfig
  let cryptoSyncStore: CryptoSyncStore

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
    copyToPasteboard: @escaping @MainActor (String) -> Void = WalletAccountHeaderView.defaultCopy,
    openExternalURL: @escaping @MainActor (URL) -> Void = WalletAccountHeaderView.defaultOpen
  ) {
    self.account = account
    self.chain = chain
    self.cryptoSyncStore = cryptoSyncStore
    self.copyToPasteboard = copyToPasteboard
    self.openExternalURL = openExternalURL
  }

  private var address: String { account.walletAddress ?? "" }

  private var truncatedAddress: String {
    WalletAccountHeaderLogic.truncateAddress(address)
  }

  private var lastSyncedText: String {
    WalletAccountHeaderLogic.lastSyncedText(
      state: cryptoSyncStore.statePerAccount[account.id], now: Date())
  }

  private var isSyncing: Bool {
    cryptoSyncStore.inProgressAccountIds.contains(account.id)
  }

  var body: some View {
    HStack(spacing: 12) {
      addressSection
      Spacer(minLength: 12)
      Text(chain.displayName)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.chainName)
      Text(lastSyncedText)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.lastSynced)
      syncButton
      overflowMenu
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.container)
  }

  private var addressSection: some View {
    HStack(spacing: 6) {
      Text(truncatedAddress)
        .font(.body.monospaced())
        .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.truncatedAddress)
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
    .disabled(isSyncing)
    .help("Sync wallet now")
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

/// Pure-logic helper for `WalletAccountHeaderView`. Owns the truncation
/// rule, the relative-time formatting for the last-synced label, and the
/// "is sync allowed" predicate so they are all unit-testable without
/// instantiating a SwiftUI view.
enum WalletAccountHeaderLogic {
  /// Truncates a `0x…` wallet address to a `0xabcd…wxyz` shape: 6 leading
  /// characters (including the `0x` prefix), an ellipsis, and 4 trailing
  /// characters. Same convention as Etherscan / wallet UIs.
  ///
  /// Addresses shorter than 11 characters fall through unchanged — they
  /// can't be truncated in a way that adds clarity, and are treated as
  /// already-displayable.
  static func truncateAddress(_ address: String) -> String {
    guard address.count >= 11 else { return address }
    let prefix = address.prefix(6)
    let suffix = address.suffix(4)
    return "\(prefix)…\(suffix)"
  }

  /// User-facing relative-time label for the wallet's last successful
  /// sync. `nil` state → "Never synced". Otherwise uses
  /// `RelativeDateTimeFormatter.short` and prefixes "Synced ".
  static func lastSyncedText(state: WalletSyncState?, now: Date) -> String {
    guard let lastSyncedAt = state?.lastSyncedAt else { return "Never synced" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let relative = formatter.localizedString(for: lastSyncedAt, relativeTo: now)
    return "Synced \(relative)"
  }

  /// Whether the "Sync now" button should be enabled for the given
  /// account, given the store's in-flight set. Mirrors
  /// `CryptoSyncStore.syncAccount`'s own guard so the UI agrees with the
  /// store's behaviour (a tap during sync is a no-op, so the button
  /// shouldn't pretend otherwise).
  static func isSyncEnabled(accountId: UUID, inProgress: Set<UUID>) -> Bool {
    !inProgress.contains(accountId)
  }
}
