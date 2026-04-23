// MoolahTests/Domain/CryptoTokenRepositoryTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoTokenRepository (InMemory)")
struct CryptoTokenRepositoryTests {
  private func makeRepository() -> InMemoryTokenRepository {
    InMemoryTokenRepository()
  }

  @Test
  func emptyRepositoryReturnsEmptyArray() async throws {
    let repo = makeRepository()
    let registrations = try await repo.loadRegistrations()
    #expect(registrations.isEmpty)
  }

  @Test
  func roundTrip_saveAndLoad() async throws {
    let repo = makeRepository()
    let registrations = Array(CryptoRegistration.builtInPresets.prefix(2))
    try await repo.saveRegistrations(registrations)
    let loaded = try await repo.loadRegistrations()
    #expect(loaded.count == 2)
    #expect(loaded[0].id == registrations[0].id)
    #expect(loaded[1].id == registrations[1].id)
  }

  @Test
  func saveOverwritesPreviousList() async throws {
    let repo = makeRepository()
    try await repo.saveRegistrations(Array(CryptoRegistration.builtInPresets.prefix(3)))
    try await repo.saveRegistrations(Array(CryptoRegistration.builtInPresets.prefix(1)))
    let loaded = try await repo.loadRegistrations()
    #expect(loaded.count == 1)
  }

  @Test
  func registrationsOnDifferentChainsAreDistinct() async throws {
    // Same-symbol tokens on different chains (USDC-Ethereum vs hypothetical USDC-Polygon)
    // must be preserved as independent registrations — the chainId is part of the identity.
    let ethUsdc = CryptoRegistration(
      instrument: .crypto(
        chainId: 1,
        contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        symbol: "USDC", name: "USD Coin (Ethereum)", decimals: 6
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        coingeckoId: "usd-coin",
        cryptocompareSymbol: "USDC",
        binanceSymbol: nil
      )
    )
    let polyUsdc = CryptoRegistration(
      instrument: .crypto(
        chainId: 137,
        contractAddress: "0x2791bca1f2de4661ed88a30c99a7a9449aa84174",
        symbol: "USDC", name: "USD Coin (Polygon)", decimals: 6
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "137:0x2791bca1f2de4661ed88a30c99a7a9449aa84174",
        coingeckoId: "usd-coin",
        cryptocompareSymbol: "USDC",
        binanceSymbol: nil
      )
    )
    let repo = makeRepository()
    try await repo.saveRegistrations([ethUsdc, polyUsdc])

    let loaded = try await repo.loadRegistrations()
    #expect(loaded.count == 2)
    let ids = Set(loaded.map(\.id))
    #expect(ids.contains(ethUsdc.id))
    #expect(ids.contains(polyUsdc.id))
    #expect(ethUsdc.id != polyUsdc.id)
  }

  @Test
  func nativeAndErc20OnSameChainAreDistinct() async throws {
    // Native ETH (chainId:1, no contract) vs ERC20 on chain 1 must be distinct registrations.
    let eth = CryptoRegistration(
      instrument: .crypto(
        chainId: 1, contractAddress: nil,
        symbol: "ETH", name: "Ethereum", decimals: 18
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:native",
        coingeckoId: "ethereum",
        cryptocompareSymbol: "ETH",
        binanceSymbol: "ETHUSDT"
      )
    )
    let uni = CryptoRegistration(
      instrument: .crypto(
        chainId: 1,
        contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
        symbol: "UNI", name: "Uniswap", decimals: 18
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
        coingeckoId: "uniswap",
        cryptocompareSymbol: "UNI",
        binanceSymbol: "UNIUSDT"
      )
    )
    let repo = makeRepository()
    try await repo.saveRegistrations([eth, uni])

    let loaded = try await repo.loadRegistrations()
    #expect(loaded.count == 2)
    let ethLoaded = try #require(loaded.first { $0.instrument.ticker == "ETH" })
    let uniLoaded = try #require(loaded.first { $0.instrument.ticker == "UNI" })
    #expect(ethLoaded.instrument.contractAddress == nil)
    #expect(uniLoaded.instrument.contractAddress != nil)
  }
}
