// Domain/Models/CryptoRegistration.swift
// swiftlint:disable multiline_arguments

import Foundation

/// Pairs a crypto instrument with its price provider mapping for persistence.
/// Replaces the legacy CryptoToken type.
struct CryptoRegistration: Codable, Sendable, Hashable, Identifiable {
  let instrument: Instrument
  let mapping: CryptoProviderMapping

  var id: String { instrument.id }

  static let builtInPresets: [CryptoRegistration] = [
    CryptoRegistration(
      instrument: .crypto(
        chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8),
      mapping: CryptoProviderMapping(
        instrumentId: "0:native", coingeckoId: "bitcoin",
        cryptocompareSymbol: "BTC", binanceSymbol: "BTCUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 10,
        contractAddress: "0x4200000000000000000000000000000000000042",
        symbol: "OP", name: "Optimism", decimals: 18
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "10:0x4200000000000000000000000000000000000042",
        coingeckoId: "optimism", cryptocompareSymbol: "OP", binanceSymbol: "OPUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 1,
        contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
        symbol: "UNI", name: "Uniswap", decimals: 18
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
        coingeckoId: "uniswap", cryptocompareSymbol: "UNI", binanceSymbol: "UNIUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 1,
        contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
        symbol: "ENS", name: "Ethereum Name Service", decimals: 18
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xc18360217d8f7ab5e7c516566761ea12ce7f9d72",
        coingeckoId: "ethereum-name-service", cryptocompareSymbol: "ENS", binanceSymbol: "ENSUSDT"
      )
    ),
  ]
}
