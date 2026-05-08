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

    // 1. CryptoCompare coin list — natives match by symbol; ERC-20s match
    //    only by `(chainId, contractAddress)`. The user-supplied ticker is
    //    untrusted for ERC-20s (a spam contract can claim any ticker), so a
    //    ticker-only fallback is intentionally excluded.
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

    // 2. CoinGecko — contract-based lookup for ERC-20s only. Runs before
    //    Binance so a CG-confirmed symbol can authorise the Binance pair
    //    attribution (issue #790). An empty `apiKey` falls through to the
    //    free public CoinGecko endpoint (`api.coingecko.com`) so users
    //    without a Pro key still get tokens like USDC priced. Production
    //    passes empty string in that case; tests that pass `nil` opt out
    //    of CoinGecko entirely so they don't hit the network.
    if let apiKey = coinGeckoApiKey, !isNative, let contractAddress {
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

    // 3. Binance exchange info. Binance has no notion of `(chainId,
    //    contractAddress)`, so for ERC-20s we only attempt the lookup when
    //    a contract-based provider (CryptoCompare or CoinGecko) has
    //    already confirmed the symbol's identity for this exact contract.
    //    Without that gate, a spam ERC-20 with a copied ticker (e.g. a
    //    fake "OP" on OP-mainnet) inherits the legitimate token's
    //    `OPUSDT` mapping and poisons the running balance — see issue
    //    #790. Native tokens may fall back to the input symbol because
    //    `(chainId, isNative)` already pins identity.
    let pairSymbolBase: String? =
      isNative ? (result.resolvedSymbol ?? symbol) : result.resolvedSymbol
    if let baseSymbol = pairSymbolBase?.uppercased(), !baseSymbol.isEmpty {
      let exchangeInfoData = try await fetchExchangeInfoData()
      let pairs = try BinanceClient.parseExchangeInfoResponse(exchangeInfoData)
      let candidate = "\(baseSymbol)USDT"
      if pairs.contains(candidate) {
        result.binanceSymbol = candidate
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
