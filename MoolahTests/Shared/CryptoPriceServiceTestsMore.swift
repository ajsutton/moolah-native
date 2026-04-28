// MoolahTests/Shared/CryptoPriceServiceTestsMore.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService — Part 2")
struct CryptoPriceServiceTestsMore {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private let btcInstrument = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
  )
  private let btcMapping = CryptoProviderMapping(
    instrumentId: "0:native", coingeckoId: "bitcoin",
    cryptocompareSymbol: "BTC", binanceSymbol: "BTCUSDT"
  )

  private var ethRegistration: CryptoRegistration {
    CryptoRegistration(instrument: ethInstrument, mapping: ethMapping)
  }
  private var btcRegistration: CryptoRegistration {
    CryptoRegistration(instrument: btcInstrument, mapping: btcMapping)
  }

  private func makeService(
    clients: [CryptoPriceClient] = [],
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil,
    resolutionClient: (any TokenResolutionClient)? = nil
  ) throws -> CryptoPriceService {
    let clientList =
      clients.isEmpty
      ? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
      : clients
    let resolved = try database ?? ProfileDatabase.openInMemory()
    return CryptoPriceService(
      clients: clientList,
      database: resolved,
      resolutionClient: resolutionClient
    )
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  /// Two service instances sharing the same `DatabaseQueue` — the second
  /// must load prices persisted by the first. Renamed from
  /// `gzipRoundTripPreservesData` after the migration to GRDB.
  @Test
  func sqlRoundTripPreservesData() async throws {
    let database = try ProfileDatabase.openInMemory()

    let service1 = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]],
      database: database
    )
    let price = try await service1.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(price == dec("1623.45"))

    let service2 = try makeService(shouldFail: true, database: database)
    let cached = try await service2.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(cached == dec("1623.45"))
  }

  // MARK: - Prefetch

  @Test
  func prefetchUpdatesCacheForRegisteredItems() async throws {
    let service = try makeService(prices: [
      "1:native": ["2026-04-11": dec("1640.00")],
      "0:native": ["2026-04-11": dec("67890.00")],
    ])
    await service.prefetchLatest(for: [ethRegistration, btcRegistration])
    let ethPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-11"))
    #expect(ethPrice == dec("1640.00"))
  }

  // MARK: - Multiple tokens cached independently

  @Test
  func differentTokensAreCachedIndependently() async throws {
    let service = try makeService(prices: [
      "1:native": ["2026-04-10": dec("1623.45")],
      "0:native": ["2026-04-10": dec("67890.00")],
    ])
    let ethPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    let btcPrice = try await service.price(
      for: btcInstrument, mapping: btcMapping, on: date("2026-04-10"))
    #expect(ethPrice == dec("1623.45"))
    #expect(btcPrice == dec("67890.00"))
  }

  // MARK: - Token resolution

  @Test
  func resolveRegistration_populatesProviderFields() async throws {
    let result = TokenResolutionResult(
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT",
      resolvedName: "Uniswap",
      resolvedSymbol: "UNI",
      resolvedDecimals: 18
    )
    let service = try makeService(resolutionClient: FixedTokenResolutionClient(result: result))

    let registration = try await service.resolveRegistration(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(registration.mapping.coingeckoId == "uniswap")
    #expect(registration.mapping.cryptocompareSymbol == "UNI")
    #expect(registration.mapping.binanceSymbol == "UNIUSDT")
    #expect(registration.instrument.name == "Uniswap")
  }

  @Test
  func resolveRegistration_noProvidersMatch_returnsPartialRegistration() async throws {
    let service = try makeService(
      resolutionClient: FixedTokenResolutionClient(result: TokenResolutionResult())
    )
    let registration = try await service.resolveRegistration(
      chainId: 999,
      contractAddress: "0xunknown",
      symbol: "UNKNOWN",
      isNative: false
    )
    #expect(registration.mapping.coingeckoId == nil)
    #expect(registration.mapping.cryptocompareSymbol == nil)
    #expect(registration.mapping.binanceSymbol == nil)
    #expect(registration.instrument.ticker == "UNKNOWN")
  }

  @Test
  func resolveRegistration_resolutionFails_throws() async throws {
    let service = try makeService(
      resolutionClient: FixedTokenResolutionClient(shouldFail: true)
    )
    await #expect(throws: (any Error).self) {
      try await service.resolveRegistration(
        chainId: 1, contractAddress: "0xabc", symbol: nil, isNative: false
      )
    }
  }

  // MARK: - Rollback test for multi-statement save

  /// Rollback contract: `CryptoPriceService.saveCache` is one
  /// `database.write` (delete prior price rows + re-insert + upsert meta).
  ///
  /// Drives the **production** `saveCache` by installing a trigger that
  /// raises `ABORT` on a sentinel date string. A second fetch through the
  /// service merges that sentinel into the cache, the production save path
  /// runs, the trigger fires inside the transaction, and the entire write
  /// must roll back — leaving prior rows untouched.
  ///
  /// Lives in this part-2 file (rather than the main `CryptoPriceServiceTests`)
  /// so that primary suite stays under SwiftLint's `type_body_length` cap.
  @Test
  func saveCacheRollsBackOnInsertFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45"), "2026-04-11": dec("1700")]],
      database: database
    )
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))

    let beforeCount = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    #expect(beforeCount > 0)

    // Install a trigger that aborts inserts carrying the sentinel date.
    // The trigger fires inside `saveCache`'s transaction so the upfront
    // DELETE for the 1:native partition + the new inserts roll back together.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_save_cache
          BEFORE INSERT ON crypto_price
          WHEN NEW.date = '9999-12-31'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Drive the real `saveCache` by feeding a price set that contains the
    // sentinel date.
    let failingService = try makeService(
      prices: ["1:native": ["9999-12-31": dec("9999.0")]],
      database: database
    )
    _ = try? await failingService.price(
      for: ethInstrument, mapping: ethMapping, on: date("9999-12-31"))

    let afterCount = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    #expect(afterCount == beforeCount)

    // Probe a specific priming row to prove the DELETE inside
    // `saveCache` was rolled back. Counts can match by accident if a
    // future regression replaces delete-and-reinsert with upsert-only —
    // re-looking-up `(1:native, 2026-04-10, 1623.45)` confirms the row
    // survived rather than being silently rewritten.
    let surviving = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .filter(CryptoPriceRecord.Columns.date == "2026-04-10")
        .fetchOne(database)
    }
    #expect(surviving != nil)
    #expect(surviving?.priceUsd == 1623.45)
  }
}
