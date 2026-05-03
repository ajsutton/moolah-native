// MoolahTests/Shared/ExchangeRateServiceTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ExchangeRateService")
struct ExchangeRateServiceTests {
  private func makeService(
    rates: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil
  ) throws -> ExchangeRateService {
    let client = FixedRateClient(rates: rates, shouldFail: shouldFail)
    let resolved = try database ?? ProfileDatabase.openInMemory()
    return ExchangeRateService(client: client, database: resolved)
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  // MARK: - Step 4a: Same-currency short-circuit

  @Test
  func sameCurrencyReturnsIdentityRate() async throws {
    let service = try makeService()
    let rate = try await service.rate(from: .AUD, to: .AUD, on: date("2025-01-15"))
    #expect(rate == Decimal(1))
  }

  // MARK: - Step 4b: Cache miss and cache hit

  @Test
  func cacheMissFetchesFromClient() async throws {
    let service = try makeService(rates: [
      "2025-01-15": ["USD": dec("0.6543")]
    ])
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    #expect(rate == dec("0.6543"))
  }

  @Test
  func cacheHitDoesNotRefetch() async throws {
    let service = try makeService(rates: [
      "2025-01-15": ["USD": dec("0.6543")]
    ])
    let first = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    let second = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    #expect(first == second)
    #expect(first == dec("0.6543"))
  }

  // MARK: - Step 4c: Fallback and error paths

  @Test
  func networkFailureFallsBackToMostRecentPriorDate() async throws {
    // Pre-populate cache by fetching Friday's rate successfully
    let fridayRates: [String: [String: Decimal]] = [
      "2025-01-17": ["USD": dec("0.6500")]
    ]
    let fridayClient = FixedRateClient(rates: fridayRates, shouldFail: false)
    let service = ExchangeRateService(
      client: fridayClient, database: try ProfileDatabase.openInMemory())

    // Fetch Friday to populate cache
    let fridayRate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-17"))
    #expect(fridayRate == dec("0.6500"))

    // Now swap to a client that returns empty for weekend (simulating no data)
    // Since we can't swap clients, we use the same service — the FixedRateClient
    // returns empty for Saturday since it has no "2025-01-18" key.
    // The fetch succeeds (no error) but returns no data, so fallback kicks in.
    let saturdayRate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-18"))
    #expect(saturdayRate == dec("0.6500"))
  }

  @Test
  func networkFailureWithEmptyCacheThrows() async throws {
    let service = try makeService(shouldFail: true)
    await #expect(throws: (any Error).self) {
      try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    }
  }

  // MARK: - Date range lookup

  @Test
  func rangeReturnsRatesForEachDay() async throws {
    let service = try makeService(rates: [
      "2026-04-07": ["USD": dec("0.630")],
      "2026-04-08": ["USD": dec("0.631")],
      "2026-04-09": ["USD": dec("0.632")],
    ])
    let results = try await service.rates(
      from: .AUD, to: .USD,
      in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results[0].rate == dec("0.630"))
    #expect(results[1].rate == dec("0.631"))
    #expect(results[2].rate == dec("0.632"))
  }

  @Test
  func rangeOnlyFetchesMissingSegments() async throws {
    let service = try makeService(rates: [
      "2026-04-07": ["USD": dec("0.630")],
      "2026-04-08": ["USD": dec("0.631")],
      "2026-04-09": ["USD": dec("0.632")],
      "2026-04-10": ["USD": dec("0.633")],
      "2026-04-11": ["USD": dec("0.634")],
    ])
    _ = try await service.rates(
      from: .AUD, to: .USD,
      in: date("2026-04-08")...date("2026-04-09")
    )
    let results = try await service.rates(
      from: .AUD, to: .USD,
      in: date("2026-04-07")...date("2026-04-11")
    )
    #expect(results.count == 5)
    #expect(results[0].rate == dec("0.630"))
    #expect(results[4].rate == dec("0.634"))
  }

  @Test
  func sameCurrencyRangeReturnsIdentity() async throws {
    let service = try makeService()
    let results = try await service.rates(
      from: .AUD, to: .AUD,
      in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results.allSatisfy { $0.rate == Decimal(1) })
  }

  // MARK: - Convert

  @Test
  func convertProducesCorrectAmount() async throws {
    let service = try makeService(rates: [
      "2026-04-11": ["USD": dec("0.632")]
    ])
    let amount = InstrumentAmount(quantity: dec("100.00"), instrument: .AUD)
    let converted = try await service.convert(amount, to: .USD, on: date("2026-04-11"))
    // 100.00 * 0.632 = 63.20
    #expect(converted.quantity == dec("100.00") * dec("0.632"))
    #expect(converted.instrument == .USD)
  }

  @Test
  func convertSameCurrencyReturnsIdentical() async throws {
    let service = try makeService()
    let amount = InstrumentAmount(quantity: dec("100.00"), instrument: .AUD)
    let converted = try await service.convert(amount, to: .AUD, on: date("2026-04-11"))
    #expect(converted.quantity == dec("100.00"))
    #expect(converted.instrument == .AUD)
  }

  @Test
  func convertUsesDecimalPrecision() async throws {
    let service = try makeService(rates: [
      "2026-04-11": ["USD": dec("0.5")]
    ])
    let amount = InstrumentAmount(quantity: dec("5.55"), instrument: .AUD)
    let converted = try await service.convert(amount, to: .USD, on: date("2026-04-11"))
    // 5.55 * 0.5 = 2.775
    #expect(converted.quantity == dec("5.55") * dec("0.5"))
  }

  // MARK: - Prefetch

  @Test
  func prefetchUpdatesCache() async throws {
    let service = try makeService(rates: [
      "2026-04-10": ["USD": dec("0.629")],
      "2026-04-11": ["USD": dec("0.632")],
    ])
    await service.prefetchLatest(base: .AUD)
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    #expect(rate == dec("0.632"))
  }

  // SQL persistence tests live in `ExchangeRateServicePersistenceTests`
  // (round-trip + rollback) so this file stays under `type_body_length`.

  @Test
  func fallbackNeverUsesFutureDate() async throws {
    // Pre-populate cache with a future date only
    let futureRates: [String: [String: Decimal]] = [
      "2025-01-20": ["USD": dec("0.6500")]
    ]
    let client = FixedRateClient(rates: futureRates, shouldFail: false)
    let service = ExchangeRateService(
      client: client, database: try ProfileDatabase.openInMemory())

    // Fetch future date to populate cache
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-20"))

    // Now request an earlier date — client returns empty (no data for Jan 15),
    // fallback should NOT use the future Jan 20 rate
    await #expect(
      throws: ExchangeRateError.noRateAvailable(base: "AUD", quote: "USD", date: "2025-01-15")
    ) {
      try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    }
  }

  // MARK: - Cold cache surrounding fetch

  /// When there is no cache for the base currency and the requested date is
  /// missing from the client (weekend / holiday / today's rate not posted),
  /// we still fetch a surrounding range wide enough to cover a recent trading
  /// day and fall back to the most-recent prior cached rate.
  @Test
  func coldCacheFallsBackToPriorTradingDayWhenRequestedDateMissing() async throws {
    // Client has data for Jan 17 (Friday) but not Jan 18 (Saturday).
    let service = try makeService(rates: [
      "2025-01-17": ["USD": dec("0.6500")]
    ])

    // First call with a cold cache on Saturday. The service should fetch a
    // month-wide surrounding range, populate cache with Jan 17, and fall
    // back to Jan 17's rate.
    let saturdayRate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-18"))
    #expect(saturdayRate == dec("0.6500"))
  }

  @Test
  func coldCacheWithNetworkErrorThrows() async throws {
    // shouldFail simulates a network error. With no prior cache and a failing
    // fetch we have nothing to fall back to, so we must throw.
    let service = try makeService(shouldFail: true)
    await #expect(throws: (any Error).self) {
      try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    }
  }

  // MARK: - Cache extension

  /// After priming the cache, requesting a date after the latest cached date
  /// should trigger a forward extension fetch. If the client returns no data
  /// for the new range (e.g., today's rate not yet posted), we fall back to
  /// the most-recent cached rate rather than throwing.
  @Test
  func futureRequestExtendsForwardAndFallsBack() async throws {
    let service = try makeService(rates: [
      "2025-01-10": ["USD": dec("0.6400")]
    ])
    // Prime the cache by fetching Jan 10.
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-10"))

    // Request Jan 15 — client has no data for this date; forward extension
    // of [Jan 11, Jan 15] returns empty. Should fall back to Jan 10's rate.
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    #expect(rate == dec("0.6400"))
  }

  /// Requesting a date before the earliest cached date should trigger a
  /// backward extension fetch and pull in data from the client for the
  /// missing historical range.
  @Test
  func pastRequestExtendsBackwardAndReturnsRate() async throws {
    let service = try makeService(rates: [
      "2025-01-15": ["USD": dec("0.6480")],
      "2025-01-25": ["USD": dec("0.6600")],
    ])
    // Prime cache with Jan 25 (earliest will be 2024-12-26 via surrounding fetch,
    // but client has no data for those dates so cache contains only Jan 25).
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-25"))

    // Request Jan 15 — backward extension fetch of [Jan 15, Jan 24] should
    // pull in Jan 15.
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    #expect(rate == dec("0.6480"))
  }

  /// Once the cache is primed, a network error on a subsequent extension
  /// fetch should still fall back to cached data rather than propagate.
  @Test
  func extensionFetchErrorFallsBackToCache() async throws {
    // Step 1: populate cache with a successful fetch.
    let primingClient = FixedRateClient(rates: [
      "2025-01-10": ["USD": dec("0.6400")]
    ])
    let database = try ProfileDatabase.openInMemory()
    let service = ExchangeRateService(client: primingClient, database: database)
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-10"))

    // Step 2: new service sharing the same database but with a failing client.
    let failingClient = FixedRateClient(shouldFail: true)
    let service2 = ExchangeRateService(client: failingClient, database: database)

    // Requesting Jan 15 triggers a forward extension fetch that fails. Should
    // still return the cached Jan 10 rate via fallback.
    let rate = try await service2.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    #expect(rate == dec("0.6400"))
  }

  // MARK: - In-range short-circuit

  /// Requests for a date strictly inside `[earliestDate, latestDate]` whose
  /// exact (date, quote) tuple is missing must be served from cache via
  /// `fallbackRate` — they must NOT trigger a network fetch. This is the
  /// hot path for chart rendering: every weekend / holiday day in the
  /// visible range falls into this case, and going to the network on each
  /// one saturates the GRDB write queue with `saveCache` rewrites.
  @Test
  func inRangeMissUsesFallbackWithoutFetching() async throws {
    let inner = FixedRateClient(rates: [
      "2025-01-17": ["USD": dec("0.6500")],  // Friday
      "2025-01-20": ["USD": dec("0.6510")],  // Monday
    ])
    let client = CountingRateClient(inner)
    let database = try ProfileDatabase.openInMemory()
    let service = ExchangeRateService(client: client, database: database)

    // Prime cache with both Friday and Monday so the cached range spans
    // the weekend.
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-17"))
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-20"))
    let primedFetches = client.fetchCount

    // Saturday Jan 18 is in `[2025-01-17, 2025-01-20]`. The exact tuple is
    // missing (Frankfurter posts no weekend rates) but `fallbackRate`
    // resolves it from Friday.
    let saturdayRate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-18"))

    #expect(saturdayRate == dec("0.6500"))
    #expect(client.fetchCount == primedFetches)
  }

}
