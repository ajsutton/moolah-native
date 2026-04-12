// Features/Settings/CryptoSettingsView.swift
import SwiftUI

struct CryptoSettingsView: View {
  @State private var store: CryptoTokenStore
  @State private var showAddToken = false
  @State private var apiKeyInput = ""

  init(cryptoPriceService: CryptoPriceService) {
    _store = State(initialValue: CryptoTokenStore(cryptoPriceService: cryptoPriceService))
  }

  var body: some View {
    Form {
      tokenListSection
      apiKeySection
    }
    .formStyle(.grouped)
    .navigationTitle("Crypto Tokens")
    .task { await store.loadTokens() }
    .sheet(isPresented: $showAddToken) {
      AddTokenSheet(store: store, isPresented: $showAddToken)
    }
  }

  // MARK: - Token List

  @ViewBuilder
  private var tokenListSection: some View {
    Section {
      if store.isLoading && store.tokens.isEmpty {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
      } else if store.tokens.isEmpty {
        ContentUnavailableView(
          "No Tokens",
          systemImage: "bitcoinsign.circle",
          description: Text("Add crypto tokens to track their prices.")
        )
      } else {
        ForEach(store.tokens, id: \.id) { token in
          tokenRow(token)
        }
        .onDelete { indexSet in
          Task {
            for index in indexSet {
              await store.removeToken(store.tokens[index])
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

  private func tokenRow(_ token: CryptoToken) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(token.symbol)
          .font(.headline)
        Text(token.name)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(CryptoToken.chainName(for: token.chainId))
        .font(.caption)
        .foregroundStyle(.secondary)
      providerIndicators(for: token)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(token.symbol), \(token.name), \(CryptoToken.chainName(for: token.chainId))"
    )
    .contextMenu {
      Button(role: .destructive) {
        Task { await store.removeToken(token) }
      } label: {
        Label("Remove", systemImage: "trash")
      }
    }
  }

  private func providerIndicators(for token: CryptoToken) -> some View {
    HStack(spacing: 4) {
      if token.coingeckoId != nil {
        Text("CG")
          .font(.caption2)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(.fill, in: RoundedRectangle(cornerRadius: 3))
      }
      if token.cryptocompareSymbol != nil {
        Text("CC")
          .font(.caption2)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(.fill, in: RoundedRectangle(cornerRadius: 3))
      }
      if token.binanceSymbol != nil {
        Text("BN")
          .font(.caption2)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(.fill, in: RoundedRectangle(cornerRadius: 3))
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
