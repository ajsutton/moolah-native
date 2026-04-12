// Domain/Repositories/TokenResolutionClient.swift
import Foundation

/// Data needed to resolve a token from provider reference data.
struct TokenResolutionResult: Sendable {
  var coingeckoId: String?
  var cryptocompareSymbol: String?
  var binanceSymbol: String?
  var resolvedName: String?
  var resolvedSymbol: String?
  var resolvedDecimals: Int?
}

/// Resolves a token's provider-specific identifiers from reference data.
protocol TokenResolutionClient: Sendable {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult
}
