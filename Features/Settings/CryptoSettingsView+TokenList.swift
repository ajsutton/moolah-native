// Features/Settings/CryptoSettingsView+TokenList.swift
import SwiftUI

/// "Registered Tokens" + "CoinGecko API Key" sections of the Crypto
/// preferences tab. Extracted from `CryptoSettingsView.swift` so the
/// main view body stays under SwiftLint's `type_body_length` and
/// `file_length` thresholds. Every member here closes over the parent
/// view's `store` / `showAddToken` / `coinGeckoApiKeyInput` bindings —
/// no new state owned at this layer.
extension CryptoSettingsView {

  // MARK: - Registered Tokens

  @ViewBuilder var tokenListSection: some View {
    Section {
      tokenListContent
    } header: {
      tokenListHeader
    }
  }

  @ViewBuilder var tokenListContent: some View {
    if store.isLoading && store.registrations.isEmpty {
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
    } else if pricedRegistrations.isEmpty {
      ContentUnavailableView(
        "No Tokens",
        systemImage: "bitcoinsign.circle",
        description: Text("Add crypto tokens to track their prices.")
      )
      .frame(maxWidth: .infinity)
    } else {
      ForEach(pricedRegistrations) { registration in
        CryptoRegistrationRow(registration: registration)
          .contextMenu {
            Button(role: .destructive) {
              Task { await store.removeRegistration(registration) }
            } label: {
              Label("Remove", systemImage: "trash")
            }
          }
      }
      .onDelete { indexSet in
        let visible = pricedRegistrations
        Task {
          for index in indexSet {
            await store.removeRegistration(visible[index])
          }
        }
      }
    }
  }

  @ViewBuilder var tokenListHeader: some View {
    HStack {
      Text("Registered Tokens")
      Spacer()
      Button {
        showAddToken = true
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Add token")
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.addTokenButton)
    }
  }

  /// Tokens that are neither `.unpriced` nor `.spam` — i.e. the set the
  /// "Registered Tokens" list shows. Filtering at the view layer keeps
  /// the store's `registrations` a single source of truth that the
  /// inbox + spam views can also read.
  var pricedRegistrations: [CryptoRegistration] {
    store.registrations.filter { $0.pricingStatus == .priced }
  }

  // MARK: - CoinGecko API Key

  var coinGeckoApiKeySection: some View {
    Section {
      coinGeckoApiKeyControl
    } header: {
      Text("CoinGecko")
    } footer: {
      Text(
        "Optional. Enables CoinGecko as the highest-priority price provider. "
          + "Requires a free Demo API key from coingecko.com."
      )
    }
  }

  @ViewBuilder var coinGeckoApiKeyControl: some View {
    if store.hasApiKey {
      HStack {
        Label("CoinGecko API Key", systemImage: "key")
        Spacer()
        Text("Configured")
          .foregroundStyle(.secondary)
        Button("Remove", role: .destructive) {
          store.clearApiKey()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    } else {
      HStack {
        SecureField("CoinGecko API Key", text: $coinGeckoApiKeyInput)
        Button("Save") {
          let trimmed = coinGeckoApiKeyInput.trimmingCharacters(in: .whitespaces)
          guard !trimmed.isEmpty else { return }
          store.saveApiKey(trimmed)
          coinGeckoApiKeyInput = ""
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(coinGeckoApiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }
}
