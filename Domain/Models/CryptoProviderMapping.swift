// Domain/Models/CryptoProviderMapping.swift
import Foundation

/// Maps a crypto instrument to its price provider identifiers.
/// Separated from Instrument because provider IDs are lookup metadata,
/// not financial instrument identity.
struct CryptoProviderMapping: Codable, Sendable, Hashable, Identifiable {
  let instrumentId: String  // Matches Instrument.id, e.g. "1:native", "10:0xabc..."

  let coingeckoId: String?
  let cryptocompareSymbol: String?
  let binanceSymbol: String?

  var id: String { instrumentId }

  /// Convert from legacy CryptoToken.
  static func from(_ token: CryptoToken) -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: token.id,
      coingeckoId: token.coingeckoId,
      cryptocompareSymbol: token.cryptocompareSymbol,
      binanceSymbol: token.binanceSymbol
    )
  }

  /// Convert legacy CryptoToken to an Instrument.
  static func instrument(from token: CryptoToken) -> Instrument {
    Instrument.crypto(
      chainId: token.chainId,
      contractAddress: token.contractAddress,
      symbol: token.symbol,
      name: token.name,
      decimals: token.decimals
    )
  }

  /// Built-in presets matching CryptoToken.builtInPresets.
  static let builtInPresets: [CryptoProviderMapping] =
    CryptoToken.builtInPresets.map { CryptoProviderMapping.from($0) }
}
