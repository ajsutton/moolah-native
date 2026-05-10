// Features/Settings/DiscoveredTokensInboxView.swift
import OSLog
import SwiftUI

/// Lists every `CryptoRegistration` whose `pricingStatus == .unpriced`.
///
/// "Unpriced" is the design's term for a token whose contract was found
/// on-chain but no price provider was able to resolve it — the row's
/// fiat contribution is intentionally zero, NOT a conversion error
/// (see `TokenPricingStatus`). The user can:
///
/// - **Mark as spam** — flips status to `.spam`, removing it from
///   aggregation and hiding it across the UI. Cache invalidation is
///   wired through `CryptoTokenStore.setStatus(_:for:)`.
/// - **Re-resolve now** — re-runs the resolver via
///   `CryptoTokenDiscoveryService.reResolve(_:chain:)`. The actor
///   coalesces concurrent resolves for the same key, so a user
///   spamming the button cannot launch duplicate network round-trips.
///
/// "Held by N accounts · X transactions" copy is intentionally left as
/// a placeholder ("Held by — accounts") until the wallet-account view's
/// leg-aggregation surface lands. Once that's available we'll thread
/// the count through the registry repository rather than inline a SQL
/// query in the view layer.
struct DiscoveredTokensInboxView: View {
  @Bindable var store: CryptoTokenStore
  let tokenDiscovery: CryptoTokenDiscoveryService?

  @State private var inFlightIds: Set<String> = []
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "DiscoveredTokensInbox")

  var body: some View {
    Form {
      if store.unpricedRegistrations.isEmpty {
        emptyState
      } else {
        Section {
          ForEach(store.unpricedRegistrations) { registration in
            row(for: registration)
          }
        } footer: {
          Text(
            "Tokens land here when an on-chain contract is found but no price "
              + "provider can resolve it. Mark obvious junk as spam; tap "
              + "\u{201C}Re-resolve\u{201D} to retry resolution for the rest."
          )
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Discovered Tokens")
  }

  @ViewBuilder private var emptyState: some View {
    Section {
      ContentUnavailableView(
        "Inbox Zero",
        systemImage: "tray",
        description: Text(
          "No unresolved tokens. New on-chain tokens that can't be priced will land here.")
      )
      .frame(maxWidth: .infinity)
    }
  }

  // MARK: - Row

  @ViewBuilder
  private func row(for registration: CryptoRegistration) -> some View {
    let isInFlight = inFlightIds.contains(registration.id)
    VStack(alignment: .leading, spacing: 6) {
      CryptoRegistrationRow(registration: registration, showsContractAddress: true)
      Text("Held by \u{2014} accounts")
        .font(.caption2)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Spacer()
        Button(role: .destructive) {
          Task { await store.setStatus(.spam, for: registration) }
        } label: {
          Label("Mark as spam", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.markSpamButton(registration.id))

        Button {
          reResolve(registration)
        } label: {
          if isInFlight {
            ProgressView().controlSize(.small)
          } else {
            Label("Re-resolve", systemImage: "arrow.clockwise")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isInFlight || tokenDiscovery == nil)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.reResolveButton(registration.id))
      }
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.discoveredRow(registration.id))
  }

  // MARK: - Actions

  /// Drives `CryptoTokenDiscoveryService.reResolve(_:chain:)`. Tracks
  /// per-row in-flight state so the button shows a spinner while a
  /// resolution is running. Errors are logged at `.error` level via
  /// `os.Logger` (the contract address is `.public` here because it's
  /// already on-screen in the row's truncated label) and otherwise
  /// dropped — the design treats resolve failures as a normal outcome
  /// (the row stays `.unpriced` and the user can retry).
  private func reResolve(_ registration: CryptoRegistration) {
    guard let tokenDiscovery else { return }
    guard let chain = chainConfig(for: registration) else {
      logger.error(
        "Re-resolve skipped — unsupported chainId for \(registration.id, privacy: .public)"
      )
      return
    }
    inFlightIds.insert(registration.id)
    Task { [tokenDiscovery, store, logger] in
      defer {
        Task { @MainActor in inFlightIds.remove(registration.id) }
      }
      do {
        _ = try await tokenDiscovery.reResolve(registration, chain: chain)
        // The actor's `reResolve` calls `registry.update(_:)` on the
        // shared repository, but the store's in-memory copy doesn't
        // see those mutations. Refresh the local cache so the row
        // disappears from the inbox once the status flips.
        await store.loadRegistrations()
      } catch {
        logger.error(
          "Re-resolve failed for \(registration.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  /// Look up the supported `ChainConfig` for a registration. Returns
  /// `nil` for chains the wallet importer doesn't yet target (so the
  /// row's button is disabled rather than crashing on a forced unwrap).
  private func chainConfig(for registration: CryptoRegistration) -> ChainConfig? {
    guard let chainId = registration.instrument.chainId else { return nil }
    return ChainConfig.config(for: chainId)
  }
}
