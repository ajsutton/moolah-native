// Shared/CompositeTokenResolutionClient.swift
import Foundation

/// Production token resolution client that queries CryptoCompare, Binance, and optionally CoinGecko
/// to populate provider-specific identifiers for a token.
struct CompositeTokenResolutionClient: TokenResolutionClient, Sendable {
  private let session: URLSession
  private let coinGeckoApiKey: String?

  // For testing: inject pre-parsed reference data
  private let preloadedCoinList: Data?
  private let preloadedExchangeInfo: Data?

  init(session: URLSession = .shared, coinGeckoApiKey: String? = nil) {
    self.session = session
    self.coinGeckoApiKey = coinGeckoApiKey
    self.preloadedCoinList = nil
    self.preloadedExchangeInfo = nil
  }

  /// Test initializer with pre-loaded reference data.
  init(coinListData: Data, exchangeInfoData: Data, coinGeckoApiKey: String?) {
    self.session = .shared
    self.coinGeckoApiKey = coinGeckoApiKey
    self.preloadedCoinList = coinListData
    self.preloadedExchangeInfo = exchangeInfoData
  }

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    var result = TokenResolutionResult()

    // 1. CryptoCompare coin list
    let coinListData = try await fetchCoinListData()
    if isNative, let symbol {
      let nativeSymbols = try CryptoCompareClient.parseNativeSymbols(coinListData)
      if nativeSymbols.contains(symbol.uppercased()) {
        result.cryptocompareSymbol = symbol.uppercased()
        result.resolvedSymbol = symbol.uppercased()
      }
    } else if let contractAddress {
      let index = try CryptoCompareClient.parseCoinListResponse(coinListData)
      if let ccSymbol = index[contractAddress.lowercased()] {
        result.cryptocompareSymbol = ccSymbol
        result.resolvedSymbol = ccSymbol
      }
    }

    // 2. Binance exchange info
    let exchangeInfoData = try await fetchExchangeInfoData()
    let pairs = try BinanceClient.parseExchangeInfoResponse(exchangeInfoData)
    let pairSymbol = (result.resolvedSymbol ?? symbol ?? "").uppercased()
    let candidate = "\(pairSymbol)USDT"
    if pairs.contains(candidate) {
      result.binanceSymbol = candidate
    }

    // 3. CoinGecko (only with API key, only for contract tokens)
    if let apiKey = coinGeckoApiKey, !apiKey.isEmpty, !isNative, let contractAddress {
      do {
        let platformMapping = try await fetchAssetPlatforms(apiKey: apiKey)
        if let platformSlug = platformMapping[chainId] {
          let url = CoinGeckoClient.contractLookupURL(
            platformId: platformSlug,
            contractAddress: contractAddress,
            apiKey: apiKey
          )
          let (data, response) = try await session.data(for: URLRequest(url: url))
          if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            let lookup = try CoinGeckoClient.parseContractLookupResponse(data)
            result.coingeckoId = lookup.id
            result.resolvedName = lookup.name
            result.resolvedSymbol = result.resolvedSymbol ?? lookup.symbol.uppercased()
            result.resolvedDecimals = lookup.decimals
          }
        }
      } catch {
        // CoinGecko resolution is best-effort
      }
    }

    return result
  }

  // MARK: - Reference data fetching

  private func fetchCoinListData() async throws -> Data {
    if let preloaded = preloadedCoinList { return preloaded }
    let url = CryptoCompareClient.coinListURL()
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return data
  }

  private func fetchExchangeInfoData() async throws -> Data {
    if let preloaded = preloadedExchangeInfo { return preloaded }
    let url = BinanceClient.exchangeInfoURL()
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return data
  }

  private func fetchAssetPlatforms(apiKey: String) async throws -> [Int: String] {
    let url = CoinGeckoClient.assetPlatformsURL(apiKey: apiKey)
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try CoinGeckoClient.parseAssetPlatformsResponse(data)
  }
}
