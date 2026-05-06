// Features/Settings/CryptoAccountsListSection.swift
import SwiftUI

/// Section of the Crypto preferences tab listing every `Account` of
/// `type == .crypto`. Each row exposes:
///
/// - The account name + chain.
/// - "Synced 2h ago" relative timestamp (or "Never synced" when no
///   `WalletSyncState` exists yet).
/// - "Sync now" button that calls `CryptoSyncStore.syncAccount(_:)`. The
///   button shows a spinner while the account is in flight and is
///   disabled to prevent re-entrant taps.
/// - Inline error caption when the most recent attempt failed
///   (`WalletSyncState.lastError != nil`).
///
/// The section hides itself when there are no crypto accounts so users
/// who haven't created one yet aren't confronted with an empty list.
struct CryptoAccountsListSection: View {
  let accountStore: AccountStore
  @Bindable var syncStore: CryptoSyncStore

  init(accountStore: AccountStore, syncStore: CryptoSyncStore) {
    self.accountStore = accountStore
    self.syncStore = syncStore
  }

  var body: some View {
    if !cryptoAccounts.isEmpty {
      Section {
        ForEach(cryptoAccounts, id: \.id) { account in
          accountRow(account)
        }
      } header: {
        Text("Crypto Accounts")
      } footer: {
        Text(
          "Crypto accounts auto-sync hourly while the app is open. "
            + "Use \u{201C}Sync now\u{201D} to refresh on demand."
        )
      }
    }
  }

  /// Filtered + sorted list of crypto accounts. Sorted by display
  /// position so the order matches the sidebar — users build a mental
  /// model of "first row in sidebar = first row here". `Accounts.ordered`
  /// is already sorted by `position`, so this is just a filter.
  private var cryptoAccounts: [Account] {
    accountStore.accounts.ordered.filter { $0.type == .crypto }
  }

  // MARK: - Row

  @ViewBuilder
  private func accountRow(_ account: Account) -> some View {
    let state = syncStore.statePerAccount[account.id]
    let isInFlight = syncStore.inProgressAccountIds.contains(account.id)

    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(account.name)
          .font(.headline)
        Text(chainSubtitle(for: account))
          .font(.caption)
          .foregroundStyle(.secondary)
        if let state {
          Text(lastSyncedCaption(for: state))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else {
          Text("Never synced")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if let error = state?.lastError {
          Text(errorCaption(for: error))
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }
      Spacer()
      syncNowButton(for: account, isInFlight: isInFlight)
    }
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.accountRow(account.id))
  }

  /// Trailing "Sync now" affordance. While a sync is running we render a
  /// `ProgressView` instead of the button so a second user tap can't
  /// queue a duplicate request — `CryptoSyncStore.syncAccount` already
  /// collapses duplicates internally, but hiding the button is the
  /// clearer affordance.
  @ViewBuilder
  private func syncNowButton(for account: Account, isInFlight: Bool) -> some View {
    if isInFlight {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Syncing")
    } else {
      Button {
        Task { await syncStore.syncAccount(account) }
      } label: {
        Label("Sync now", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.syncNowButton(account.id))
    }
  }

  // MARK: - Caption formatting

  private func chainSubtitle(for account: Account) -> String {
    if let chainId = account.chainId {
      return Instrument.chainName(for: chainId)
    }
    return account.instrument.displaySymbol ?? account.instrument.name
  }

  /// "Synced 2h ago" relative caption. Uses `RelativeDateTimeFormatter`
  /// with `.short` units to match `ImportRulesSettingsView`'s existing
  /// idiom — keeps the project's relative-date language consistent.
  private func lastSyncedCaption(for state: WalletSyncState) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let relative = formatter.localizedString(for: state.lastSyncedAt, relativeTo: Date())
    return "Synced \(relative)"
  }

  private func errorCaption(for error: WalletSyncError) -> String {
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
