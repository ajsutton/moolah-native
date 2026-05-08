// Features/Settings/CryptoRegistrationRow.swift
import SwiftUI

/// Compact row used by the Registered Tokens, Discovered Tokens inbox,
/// and Spam Tokens management lists. Renders the instrument's symbol,
/// name, chain, optional contract address (shown in full so a spoofed
/// contract can't hide behind a truncation ellipsis), and the badge set
/// derived from the row's `CryptoProviderMapping`.
///
/// `CryptoRegistrationRow` is read-only — actions (remove, mark-spam,
/// re-resolve, restore) live as `contextMenu` / trailing buttons on the
/// callsite so each list controls its own affordances. The row renders
/// the same underlying data shape regardless of `pricingStatus`, which
/// keeps the inbox + spam screens visually consistent with the main
/// list.
struct CryptoRegistrationRow: View {
  let registration: CryptoRegistration
  /// Whether to render the truncated contract address line. Off in the
  /// main "Registered Tokens" list (the row is dense already) and on in
  /// the inbox / spam views, where the address is the operative
  /// disambiguator for tokens with shared symbols.
  let showsContractAddress: Bool

  init(registration: CryptoRegistration, showsContractAddress: Bool = false) {
    self.registration = registration
    self.showsContractAddress = showsContractAddress
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(instrument.ticker ?? instrument.name)
          .font(.headline)
        Text(instrument.name)
          .font(.caption)
          .foregroundStyle(.secondary)
        if showsContractAddress, let address = instrument.contractAddress {
          // Full address — never truncated. A trailing-ellipsis form
          // can hide the only character that distinguishes a legitimate
          // contract from a spoofed one (issue #790). `.textSelection`
          // lets the user copy it to compare against an explorer.
          Text(address)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      Spacer()
      Text(Instrument.chainName(for: instrument.chainId ?? 0))
        .font(.caption)
        .foregroundStyle(.secondary)
      providerIndicators(for: registration.mapping)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var instrument: Instrument { registration.instrument }

  private var accessibilityLabel: String {
    let mapping = registration.mapping
    var parts: [String] = [
      instrument.ticker ?? instrument.name,
      instrument.name,
      Instrument.chainName(for: instrument.chainId ?? 0),
    ]
    if let address = instrument.contractAddress {
      parts.append("contract \(address)")
    }
    parts.append(providersAccessibilityFragment(for: mapping))
    return parts.filter { !$0.isEmpty }.joined(separator: ", ")
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
    return names.isEmpty ? "" : "priced via " + names.joined(separator: ", ")
  }

  @ViewBuilder
  private func providerIndicators(for mapping: CryptoProviderMapping) -> some View {
    HStack(spacing: 4) {
      if mapping.coingeckoId != nil {
        providerBadge("CG", accessibilityLabel: "CoinGecko")
      }
      if mapping.cryptocompareSymbol != nil {
        providerBadge("CC", accessibilityLabel: "CryptoCompare")
      }
      if mapping.binanceSymbol != nil {
        providerBadge("BN", accessibilityLabel: "Binance")
      }
    }
  }

  private func providerBadge(_ text: String, accessibilityLabel: String) -> some View {
    Text(text)
      .font(.caption2)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(.fill, in: RoundedRectangle(cornerRadius: 3))
      .accessibilityLabel(accessibilityLabel)
  }
}
