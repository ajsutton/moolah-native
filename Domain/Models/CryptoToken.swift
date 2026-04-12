// Domain/Models/CryptoToken.swift
import Foundation

/// A cryptocurrency token identified by chain ID + contract address.
/// Provider-specific fields are resolved at registration time and persisted.
struct CryptoToken: Codable, Sendable, Hashable, Identifiable {
  let chainId: Int
  let contractAddress: String?
  let symbol: String
  let name: String
  let decimals: Int

  // Provider-specific identifiers, resolved at registration time
  let coingeckoId: String?
  let cryptocompareSymbol: String?
  let binanceSymbol: String?

  var id: String {
    if let contractAddress {
      return "\(chainId):\(contractAddress.lowercased())"
    }
    return "\(chainId):native"
  }

  // Equality and hashing based on identity (chain + address), not display fields
  static func == (lhs: CryptoToken, rhs: CryptoToken) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

extension CryptoToken {
  static func chainName(for chainId: Int) -> String {
    switch chainId {
    case 0: "Bitcoin"
    case 1: "Ethereum"
    case 10: "Optimism"
    case 137: "Polygon"
    case 42161: "Arbitrum"
    case 8453: "Base"
    case 43114: "Avalanche"
    default: "Chain \(chainId)"
    }
  }

  static let builtInPresets: [CryptoToken] = [
    CryptoToken(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin",
      decimals: 8, coingeckoId: "bitcoin", cryptocompareSymbol: "BTC",
      binanceSymbol: "BTCUSDT"
    ),
    CryptoToken(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18, coingeckoId: "ethereum", cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    ),
    CryptoToken(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18,
      coingeckoId: "optimism", cryptocompareSymbol: "OP",
      binanceSymbol: "OPUSDT"
    ),
    CryptoToken(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: "UNI", name: "Uniswap", decimals: 18,
      coingeckoId: "uniswap", cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT"
    ),
    CryptoToken(
      chainId: 1,
      contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
      symbol: "ENS", name: "Ethereum Name Service", decimals: 18,
      coingeckoId: "ethereum-name-service", cryptocompareSymbol: "ENS",
      binanceSymbol: "ENSUSDT"
    ),
  ]
}
