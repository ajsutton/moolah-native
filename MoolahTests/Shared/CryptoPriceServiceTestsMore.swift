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

  /// Rollback contract: `CryptoPriceService.persistDelta` writes the
  /// delta rows (`INSERT OR REPLACE`) plus the meta row inside a single
  /// `database.write` transaction. If any statement throws, every
  /// statement in the same closure must roll back together so prior
  /// rows survive untouched.
  ///
  /// Drives the **production** save path by installing a trigger that
  /// raises `ABORT` on a sentinel date. A second fetch through the
  /// service merges that sentinel, `persistDelta` writes the row, the
  /// trigger aborts mid-transaction, and SQLite rolls the meta insert
  /// back along with it.
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
    // The trigger fires inside `persistDelta`'s transaction so the
    // failed `INSERT OR REPLACE` and the meta insert roll back together.
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

    // Drive the real `persistDelta` by feeding a price set that
    // contains the sentinel date.
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

    // Probe a specific priming row to prove the original insert
    // survived the aborted transaction. The exact-row check matters
    // because `persistDelta` is upsert-only (no DELETE), so a row-count
    // assertion alone would pass even if the rollback hadn't fired.
    // Re-looking-up `(1:native, 2026-04-10, 1623.45)` by value proves
    // the original write is intact.
    let surviving = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .filter(CryptoPriceRecord.Columns.date == "2026-04-10")
        .fetchOne(database)
    }
    #expect(surviving != nil)
    #expect(surviving?.priceUsd == 1623.45)
  }

  // MARK: - Persistence efficiency

  /// `prefetchLatest` must skip the disk write when the latest price is
  /// already cached at the same value. The pre-fix code unconditionally
  /// rewrote the entire token partition on every prefetch, so a periodic
  /// "no change since last poll" tick still saturated the GRDB queue.
  /// Detected via an `AFTER INSERT ON crypto_price` counter trigger.
  @Test
  func prefetchWithUnchangedPriceDoesNotRewriteCache() async throws {
    let database = try ProfileDatabase.openInMemory()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let today = formatter.string(from: Date())
    let service = try makeService(
      prices: ["1:native": [today: dec("1623.45")]],
      database: database
    )

    // Prime the cache by running prefetchLatest once.
    await service.prefetchLatest(for: [ethRegistration])

    // Install the counter only AFTER priming so we measure just the
    // second (no-op) prefetch.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TABLE crypto_price_write_counter (n INTEGER NOT NULL);
          INSERT INTO crypto_price_write_counter (n) VALUES (0);
          CREATE TRIGGER count_crypto_price_writes
          AFTER INSERT ON crypto_price
          BEGIN
              UPDATE crypto_price_write_counter SET n = n + 1;
          END;
          """)
    }

    // Same price still in client; prefetch returns unchanged data.
    await service.prefetchLatest(for: [ethRegistration])

    let writes = try await database.read { database in
      try Int.fetchOne(database, sql: "SELECT n FROM crypto_price_write_counter") ?? -1
    }
    #expect(writes == 0)
  }

  /// `persistDelta` must persist only the rows the latest fetch added
  /// or changed. With the pre-fix delete-all + insert-each path a fetch
  /// returning N existing dates plus M new dates wrote N+M rows; with
  /// delta-write only the M new dates are persisted.
  @Test
  func saveCacheWritesOnlyChangedRows() async throws {
    let database = try ProfileDatabase.openInMemory()
    // Client has data for both Apr 10 (priming target) and Apr 15
    // (subsequent target). The Apr 15 cold-cache 30-day fetch returns
    // both dates, but Apr 10 is already cached at the same value.
    let service = try makeService(
      prices: [
        "1:native": [
          "2026-04-10": dec("1623.45"),
          "2026-04-15": dec("1700.00"),
        ]
      ],
      database: database
    )

    // Prime cache by fetching Apr 10.
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))

    let primedCount = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    #expect(primedCount >= 1)

    // Install the counter after priming so it only sees the second save.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TABLE crypto_price_write_counter (n INTEGER NOT NULL);
          INSERT INTO crypto_price_write_counter (n) VALUES (0);
          CREATE TRIGGER count_crypto_price_writes
          AFTER INSERT ON crypto_price
          BEGIN
              UPDATE crypto_price_write_counter SET n = n + 1;
          END;
          """)
    }

    // Cold-cache 30-day fetch for Apr 15 returns {Apr 10, Apr 15}.
    // Apr 10 is unchanged; only Apr 15 is a delta.
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-15"))

    let writes = try await database.read { database in
      try Int.fetchOne(database, sql: "SELECT n FROM crypto_price_write_counter") ?? -1
    }
    #expect(writes == 1)
  }
}
