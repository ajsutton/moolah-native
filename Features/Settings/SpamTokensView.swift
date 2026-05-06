// Features/Settings/SpamTokensView.swift
import SwiftUI

/// Lists every `CryptoRegistration` whose `pricingStatus == .spam`.
///
/// Spam classification can come from three sources, all surfaced
/// through the same list:
///
/// - Alchemy's `isSpam` flag set during initial discovery.
/// - The user's "Mark as spam" action in the Discovered Tokens inbox.
/// - A spam classification synced from another device.
///
/// The single per-row action is **Restore** — flips the status back to
/// `.unpriced` so the row returns to the Discovered Tokens inbox. From
/// there the user can either re-resolve manually or wait for the next
/// daily auto-resolution cycle to pick it back up. We deliberately do
/// not jump directly to `.priced` because the resolver hasn't been
/// re-run; the canonical "make this a priced token" path stays
/// `Inbox → Re-resolve`.
///
/// Cache invalidation is wired through `CryptoTokenStore.setStatus(_:for:)`,
/// so historical balances recompute the moment a row is restored.
struct SpamTokensView: View {
  @Bindable var store: CryptoTokenStore

  var body: some View {
    Form {
      if store.spamRegistrations.isEmpty {
        Section {
          ContentUnavailableView(
            "No Spam Tokens",
            systemImage: "trash",
            description: Text("Tokens marked as spam (by you or by Alchemy) will appear here.")
          )
          .frame(maxWidth: .infinity)
        }
      } else {
        Section {
          ForEach(store.spamRegistrations) { registration in
            row(for: registration)
          }
        } footer: {
          Text(
            "Spam tokens contribute zero to fiat balances and are hidden across the app. "
              + "Restore a row to move it back to the Discovered Tokens inbox."
          )
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Spam Tokens")
  }

  // MARK: - Row

  @ViewBuilder
  private func row(for registration: CryptoRegistration) -> some View {
    HStack(alignment: .center, spacing: 12) {
      CryptoRegistrationRow(registration: registration, showsContractAddress: true)
      Button {
        Task { await store.setStatus(.unpriced, for: registration) }
      } label: {
        Label("Restore", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.restoreButton(registration.id))
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.spamRow(registration.id))
  }
}
