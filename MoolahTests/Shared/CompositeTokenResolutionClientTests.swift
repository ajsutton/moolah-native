// MoolahTests/Shared/CompositeTokenResolutionClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CompositeTokenResolutionClient")
struct CompositeTokenResolutionClientTests {

  @Test func resolve_contractToken_findsCryptoCompareAndBinance() async throws {
    let ccCoinList = """
      {
          "Data": {
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              }
          }
      }
      """.data(using: .utf8)!

    let binanceInfo = """
      {
          "symbols": [
              { "symbol": "UNIUSDT", "baseAsset": "UNI", "quoteAsset": "USDT", "status": "TRADING" }
          ]
      }
      """.data(using: .utf8)!

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKey: nil
    )

    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(result.cryptocompareSymbol == "UNI")
    #expect(result.binanceSymbol == "UNIUSDT")
  }

  @Test func resolve_nativeToken_matchesBySymbol() async throws {
    let ccCoinList = """
      {
          "Data": {
              "BTC": { "Symbol": "BTC", "CoinName": "Bitcoin", "SmartContractAddress": "N/A" },
              "WBTC": { "Symbol": "WBTC", "CoinName": "Wrapped BTC", "SmartContractAddress": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" }
          }
      }
      """.data(using: .utf8)!

    let binanceInfo = """
      {
          "symbols": [
              { "symbol": "BTCUSDT", "baseAsset": "BTC", "quoteAsset": "USDT", "status": "TRADING" }
          ]
      }
      """.data(using: .utf8)!

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKey: nil
    )

    let result = try await client.resolve(
      chainId: 0, contractAddress: nil, symbol: "BTC", isNative: true
    )
    #expect(result.cryptocompareSymbol == "BTC")
    #expect(result.binanceSymbol == "BTCUSDT")
  }

  @Test func resolve_unknownToken_returnsEmptyResult() async throws {
    let ccCoinList = """
      { "Data": {} }
      """.data(using: .utf8)!

    let binanceInfo = """
      { "symbols": [] }
      """.data(using: .utf8)!

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKey: nil
    )

    let result = try await client.resolve(
      chainId: 999, contractAddress: "0xunknown", symbol: "NOPE", isNative: false
    )
    #expect(result.cryptocompareSymbol == nil)
    #expect(result.binanceSymbol == nil)
    #expect(result.coingeckoId == nil)
  }

  @Test func resolve_matchesContractAddressRegardlessOfCase() async throws {
    // CoinList uses lowercase addresses; callers may pass checksummed (mixed-case).
    let ccCoinList = """
      {
          "Data": {
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              }
          }
      }
      """.data(using: .utf8)!

    let binanceInfo = """
      { "symbols": [] }
      """.data(using: .utf8)!

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKey: nil
    )

    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0x1F9840A85D5AF5BF1D1762F925BDADDC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(result.cryptocompareSymbol == "UNI")
  }

  @Test func resolve_nativeOnDifferentChainsAreDistinct() async throws {
    // Resolving native tokens on two different chainIds should not conflate them —
    // the chainId combined with symbol scopes the lookup.
    let ccCoinList = """
      {
          "Data": {
              "ETH": { "Symbol": "ETH", "CoinName": "Ethereum", "SmartContractAddress": "N/A" },
              "MATIC": { "Symbol": "MATIC", "CoinName": "Polygon", "SmartContractAddress": "N/A" }
          }
      }
      """.data(using: .utf8)!

    let binanceInfo = """
      { "symbols": [] }
      """.data(using: .utf8)!

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKey: nil
    )

    let eth = try await client.resolve(
      chainId: 1, contractAddress: nil, symbol: "ETH", isNative: true
    )
    let matic = try await client.resolve(
      chainId: 137, contractAddress: nil, symbol: "MATIC", isNative: true
    )
    #expect(eth.cryptocompareSymbol == "ETH")
    #expect(matic.cryptocompareSymbol == "MATIC")
  }
}
