// Features/Settings/CryptoSettingsView.swift
import SwiftUI

struct CryptoSettingsView: View {
  @Bindable var store: CryptoTokenStore
  @State private var showAddToken = false
  @State private var apiKeyInput = ""

  var body: some View {
    Form {
      tokenListSection
      apiKeySection
    }
    .formStyle(.grouped)
    .navigationTitle("Crypto Tokens")
    .task { await store.loadRegistrations() }
    .sheet(isPresented: $showAddToken) {
      AddTokenSheet {
        Task { await store.loadRegistrations() }
      }
    }
  }

  // MARK: - Token List

  @ViewBuilder private var tokenListSection: some View {
    Section {
      if store.isLoading && store.registrations.isEmpty {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
      } else if store.registrations.isEmpty {
        ContentUnavailableView(
          "No Tokens",
          systemImage: "bitcoinsign.circle",
          description: Text("Add crypto tokens to track their prices.")
        )
        .frame(maxWidth: .infinity)
      } else {
        ForEach(store.registrations) { registration in
          registrationRow(registration)
        }
        .onDelete { indexSet in
          Task {
            for index in indexSet {
              await store.removeRegistration(store.registrations[index])
            }
          }
        }
      }
    } header: {
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
      }
    }
  }

  private func registrationRow(_ registration: CryptoRegistration) -> some View {
    let instrument = registration.instrument
    let mapping = registration.mapping
    return HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(instrument.ticker ?? instrument.name)
          .font(.headline)
        Text(instrument.name)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(Instrument.chainName(for: instrument.chainId ?? 0))
        .font(.caption)
        .foregroundStyle(.secondary)
      providerIndicators(for: mapping)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(instrument.ticker ?? instrument.name), \(instrument.name), "
        + "\(Instrument.chainName(for: instrument.chainId ?? 0))"
        + providersAccessibilityFragment(for: mapping)
    )
    .contextMenu {
      Button(role: .destructive) {
        Task { await store.removeRegistration(registration) }
      } label: {
        Label("Remove", systemImage: "trash")
      }
    }
  }

  /// VoiceOver fragment listing the active price providers for a mapping.
  /// The visual `CG`/`CC`/`BN` badges in `providerIndicators` would otherwise
  /// be silent — a combined-element row reads only the outer label, so each
  /// badge's individual `accessibilityLabel` doesn't surface.
  private func providersAccessibilityFragment(for mapping: CryptoProviderMapping) -> String {
    let names: [String] = [
      mapping.coingeckoId != nil ? "CoinGecko" : nil,
      mapping.cryptocompareSymbol != nil ? "CryptoCompare" : nil,
      mapping.binanceSymbol != nil ? "Binance" : nil,
    ].compactMap { $0 }
    return names.isEmpty ? "" : ", priced via " + names.joined(separator: ", ")
  }

  private func providerIndicators(for mapping: CryptoProviderMapping) -> some View {
    HStack(spacing: 4) {
      if mapping.coingeckoId != nil {
        Text("CG")
          .font(.caption2)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(.fill, in: RoundedRectangle(cornerRadius: 3))
          .accessibilityLabel("CoinGecko")
      }
      if mapping.cryptocompareSymbol != nil {
        Text("CC")
          .font(.caption2)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(.fill, in: RoundedRectangle(cornerRadius: 3))
          .accessibilityLabel("CryptoCompare")
      }
      if mapping.binanceSymbol != nil {
        Text("BN")
          .font(.caption2)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(.fill, in: RoundedRectangle(cornerRadius: 3))
          .accessibilityLabel("Binance")
      }
    }
  }

  // MARK: - API Key

  private var apiKeySection: some View {
    Section {
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
          SecureField("CoinGecko API Key", text: $apiKeyInput)
          Button("Save") {
            let trimmed = apiKeyInput.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            store.saveApiKey(trimmed)
            apiKeyInput = ""
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    } header: {
      Text("CoinGecko")
    } footer: {
      Text(
        "Optional. Enables CoinGecko as the highest-priority price provider. Requires a free Demo API key from coingecko.com."
      )
    }
  }
}
