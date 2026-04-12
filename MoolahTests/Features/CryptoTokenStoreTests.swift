// MoolahTests/Features/CryptoTokenStoreTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoTokenStore")
@MainActor
struct CryptoTokenStoreTests {
  private func makeStore(
    registrations: [CryptoRegistration] = [],
    resolutionResult: TokenResolutionResult = TokenResolutionResult(),
    resolutionFails: Bool = false
  ) async -> CryptoTokenStore {
    let repo = InMemoryTokenRepository()
    if !registrations.isEmpty {
      try? await repo.saveRegistrations(registrations)
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

  @Test func loadRegistrations_populatesList() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let store = await makeStore(registrations: presets)
    await store.loadRegistrations()
    #expect(store.registrations.count == 2)
  }

  @Test func loadRegistrations_populatesInstruments() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let store = await makeStore(registrations: presets)
    await store.loadRegistrations()
    #expect(store.instruments.count == 2)
    #expect(store.instruments.allSatisfy { $0.kind == .cryptoToken })
  }

  @Test func loadRegistrations_populatesProviderMappings() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let store = await makeStore(registrations: presets)
    await store.loadRegistrations()
    #expect(store.providerMappings.count == 2)
    let btcMapping = store.providerMappings["0:native"]
    #expect(btcMapping?.coingeckoId == "bitcoin")
  }

  @Test func removeRegistration_removesFromList() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let store = await makeStore(registrations: presets)
    await store.loadRegistrations()
    await store.removeRegistration(presets[0])
    #expect(store.registrations.count == 1)
    #expect(store.registrations[0].id == presets[1].id)
    #expect(store.instruments.count == 1)
  }

  @Test func removeInstrument_removesFromAllCollections() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let store = await makeStore(registrations: presets)
    await store.loadRegistrations()
    let instrumentToRemove = store.instruments[0]
    await store.removeInstrument(instrumentToRemove)
    #expect(store.registrations.count == 1)
    #expect(store.instruments.count == 1)
    #expect(store.providerMappings[instrumentToRemove.id] == nil)
  }

  @Test func resolveToken_populatesResolvedRegistration() async {
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
    #expect(store.resolvedRegistration != nil)
    #expect(store.resolvedRegistration?.mapping.coingeckoId == "uniswap")
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
    #expect(store.resolvedRegistration?.instrument.kind == .cryptoToken)
    #expect(store.resolvedRegistration?.mapping.coingeckoId == "uniswap")
  }

  @Test func resolveToken_failure_setsError() async {
    let store = await makeStore(resolutionFails: true)
    await store.resolveToken(
      chainId: 1, contractAddress: "0xabc", symbol: nil, isNative: false
    )
    #expect(store.resolvedRegistration == nil)
    #expect(store.error != nil)
  }

  @Test func confirmRegistration_addsToList() async {
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
    #expect(store.registrations.count == 1)
    #expect(store.instruments.count == 1)
    #expect(store.resolvedRegistration == nil)
  }
}
