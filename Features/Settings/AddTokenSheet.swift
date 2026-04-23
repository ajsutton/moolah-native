// Features/Settings/AddTokenSheet.swift
import SwiftUI

struct AddTokenSheet: View {
  @Bindable var store: CryptoTokenStore
  @Binding var isPresented: Bool

  @State private var contractAddress = ""
  @State private var selectedChainId = 1
  @State private var isNative = false
  @State private var symbolHint = ""

  private let chains: [(id: Int, name: String)] = [
    (0, "Bitcoin"),
    (1, "Ethereum"),
    (10, "Optimism"),
    (137, "Polygon"),
    (42161, "Arbitrum"),
    (8453, "Base"),
    (43114, "Avalanche"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        if store.resolvedRegistration != nil {
          confirmationSection
        } else if store.isResolving {
          resolvingSection
        } else {
          inputSection
        }

        if let error = store.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .accessibilityLabel("Error: \(error)")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Add Token")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            store.resolvedRegistration = nil
            isPresented = false
          }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 400, minHeight: 300)
    #endif
  }

  // MARK: - Input

  private var inputSection: some View {
    Group {
      Section("Token Type") {
        Toggle("Native / Layer-1 token", isOn: $isNative)
      }

      if isNative {
        Section("Token") {
          Picker("Chain", selection: $selectedChainId) {
            ForEach(chains, id: \.id) { chain in
              Text(chain.name).tag(chain.id)
            }
          }
          TextField("Symbol (e.g. BTC)", text: $symbolHint)
            .autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.characters)
            #endif
        }
      } else {
        Section("Contract") {
          Picker("Chain", selection: $selectedChainId) {
            ForEach(chains, id: \.id) { chain in
              Text(chain.name).tag(chain.id)
            }
          }
          TextField("Contract address (0x...)", text: $contractAddress)
            .autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.never)
              .keyboardType(.asciiCapable)
            #endif
          TextField("Symbol hint (optional)", text: $symbolHint)
            .autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.characters)
            #endif
        }
      }

      Section {
        Button("Resolve Token") {
          Task {
            await store.resolveToken(
              chainId: selectedChainId,
              contractAddress: isNative
                ? nil : contractAddress.trimmingCharacters(in: .whitespaces),
              symbol: symbolHint.isEmpty ? nil : symbolHint.trimmingCharacters(in: .whitespaces),
              isNative: isNative
            )
          }
        }
        #if os(iOS)
          .buttonStyle(.borderedProminent)
        #else
          .buttonStyle(.bordered)
        #endif
        .disabled(isNative ? symbolHint.isEmpty : contractAddress.isEmpty)
      }
    }
  }

  // MARK: - Resolving

  private var resolvingSection: some View {
    Section {
      HStack {
        Spacer()
        ProgressView("Resolving token\u{2026}")
        Spacer()
      }
    }
  }

  // MARK: - Confirmation

  @ViewBuilder private var confirmationSection: some View {
    if let registration = store.resolvedRegistration {
      let instrument = registration.instrument
      let mapping = registration.mapping
      Section("Resolved Token") {
        LabeledContent("Name", value: instrument.name)
        LabeledContent("Symbol", value: instrument.ticker ?? instrument.name)
        LabeledContent("Chain", value: Instrument.chainName(for: instrument.chainId ?? 0))
        LabeledContent("Decimals") {
          Text("\(instrument.decimals)").monospacedDigit()
        }
      }

      Section("Provider Coverage") {
        providerRow("CoinGecko", available: mapping.coingeckoId != nil)
        providerRow("CryptoCompare", available: mapping.cryptocompareSymbol != nil)
        providerRow("Binance", available: mapping.binanceSymbol != nil)
      }

      if mapping.coingeckoId == nil && mapping.cryptocompareSymbol == nil
        && mapping.binanceSymbol == nil
      {
        Section {
          Label(
            "No providers could resolve this token. Price data will not be available.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.red)
        }
      }

      Section {
        HStack {
          Button("Back") {
            store.resolvedRegistration = nil
          }
          Spacer()
          Button("Add Token") {
            Task {
              await store.confirmRegistration()
              isPresented = false
            }
          }
          #if os(iOS)
            .buttonStyle(.borderedProminent)
          #else
            .buttonStyle(.bordered)
          #endif
        }
      }
    }
  }

  private func providerRow(_ name: String, available: Bool) -> some View {
    HStack {
      Text(name)
      Spacer()
      Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
        .foregroundStyle(available ? .primary : .secondary)
        .accessibilityLabel(available ? "\(name) available" : "\(name) not available")
    }
  }

}
