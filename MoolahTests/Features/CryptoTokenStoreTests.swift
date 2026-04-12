// MoolahTests/Features/CryptoTokenStoreTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoTokenStore")
@MainActor
struct CryptoTokenStoreTests {
  private func makeStore(
    tokens: [CryptoToken] = [],
    resolutionResult: TokenResolutionResult = TokenResolutionResult(),
    resolutionFails: Bool = false
  ) async -> CryptoTokenStore {
    let repo = InMemoryTokenRepository()
    if !tokens.isEmpty {
      try? await repo.saveTokens(tokens)
    }
    let service = CryptoPriceService(
      clients: [FixedCryptoPriceClient()],
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("crypto-store-tests")
        .appendingPathComponent(UUID().uuidString),
      tokenRepository: repo,
      resolutionClient: FixedTokenResolutionClient(
        result: resolutionResult,
        shouldFail: resolutionFails
      )
    )
    return CryptoTokenStore(cryptoPriceService: service)
  }

  @Test func loadTokens_populatesTokenList() async {
    let presets = Array(CryptoToken.builtInPresets.prefix(2))
    let store = await makeStore(tokens: presets)
    await store.loadTokens()
    #expect(store.tokens.count == 2)
  }

  @Test func loadTokens_populatesCryptoInstruments() async {
    let presets = Array(CryptoToken.builtInPresets.prefix(2))
    let store = await makeStore(tokens: presets)
    await store.loadTokens()
    #expect(store.cryptoInstruments.count == 2)
    #expect(store.cryptoInstruments.allSatisfy { $0.kind == .cryptoToken })
  }

  @Test func loadTokens_populatesProviderMappings() async {
    let presets = Array(CryptoToken.builtInPresets.prefix(2))
    let store = await makeStore(tokens: presets)
    await store.loadTokens()
    #expect(store.providerMappings.count == 2)
    let btcMapping = store.providerMappings["0:native"]
    #expect(btcMapping?.coingeckoId == "bitcoin")
  }

  @Test func removeToken_removesFromList() async {
    let presets = Array(CryptoToken.builtInPresets.prefix(2))
    let store = await makeStore(tokens: presets)
    await store.loadTokens()
    await store.removeToken(presets[0])
    #expect(store.tokens.count == 1)
    #expect(store.tokens[0].id == presets[1].id)
    #expect(store.cryptoInstruments.count == 1)
  }

  @Test func removeInstrument_removesFromAllCollections() async {
    let presets = Array(CryptoToken.builtInPresets.prefix(2))
    let store = await makeStore(tokens: presets)
    await store.loadTokens()
    let instrumentToRemove = store.cryptoInstruments[0]
    await store.removeInstrument(instrumentToRemove)
    #expect(store.tokens.count == 1)
    #expect(store.cryptoInstruments.count == 1)
    #expect(store.providerMappings[instrumentToRemove.id] == nil)
  }

  @Test func resolveToken_populatesResolvedToken() async {
    let result = TokenResolutionResult(
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT",
      resolvedName: "Uniswap",
      resolvedSymbol: "UNI",
      resolvedDecimals: 18
    )
    let store = await makeStore(resolutionResult: result)
    await store.resolveToken(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(store.resolvedToken != nil)
    #expect(store.resolvedToken?.coingeckoId == "uniswap")
  }

  @Test func resolveToken_populatesInstrumentAndMapping() async {
    let result = TokenResolutionResult(
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT",
      resolvedName: "Uniswap",
      resolvedSymbol: "UNI",
      resolvedDecimals: 18
    )
    let store = await makeStore(resolutionResult: result)
    await store.resolveToken(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(store.resolvedInstrument?.kind == .cryptoToken)
    #expect(store.resolvedMapping?.coingeckoId == "uniswap")
  }

  @Test func resolveToken_failure_setsError() async {
    let store = await makeStore(resolutionFails: true)
    await store.resolveToken(
      chainId: 1, contractAddress: "0xabc", symbol: nil, isNative: false
    )
    #expect(store.resolvedToken == nil)
    #expect(store.resolvedInstrument == nil)
    #expect(store.error != nil)
  }

  @Test func confirmRegistration_addsToTokenList() async {
    let result = TokenResolutionResult(
      cryptocompareSymbol: "UNI",
      resolvedName: "Uniswap",
      resolvedSymbol: "UNI",
      resolvedDecimals: 18
    )
    let store = await makeStore(resolutionResult: result)
    await store.resolveToken(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    await store.confirmRegistration()
    #expect(store.tokens.count == 1)
    #expect(store.cryptoInstruments.count == 1)
    #expect(store.resolvedToken == nil)
    #expect(store.resolvedInstrument == nil)
  }
}
