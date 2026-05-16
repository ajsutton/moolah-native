// MoolahTests/Shared/ExchangeRateServiceFallbackTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the exact / gap / post-latest / identity / pre-history semantics of
/// `ExchangeRateService` so the `SortedDateSeries` migration is provably
/// behavior-preserving. Mirrors the real FX test harness
/// (`FixedRateClient` + `ProfileIndexDatabase.openInMemory()`).
@Suite("ExchangeRateService fallback semantics")
struct ExchangeRateServiceFallbackTests {
  private func makeService(
    _ rates: [String: [String: Decimal]]
  ) throws -> ExchangeRateService {
    let client = FixedRateClient(rates: rates)
    let database = try ProfileIndexDatabase.openInMemory()
    return ExchangeRateService(
      client: client, database: database, now: { self.date("2024-02-01") })
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    // swiftlint:disable:next force_unwrapping
    return formatter.date(from: string)!
  }

  @Test("exact / gap / post-latest match prior-implementation semantics")
  func behaviorMatrix() async throws {
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.fiat(code: "AUD")
    let service = try makeService([
      "2024-01-15": ["AUD": dec("1.50")],
      "2024-01-16": ["AUD": dec("1.51")],
      "2024-01-17": ["AUD": dec("1.52")],
    ])
    _ = try await service.rate(from: usd, to: aud, on: date("2024-01-17"))
    #expect(
      try await service.rate(from: usd, to: aud, on: date("2024-01-16"))
        == dec("1.51"))
    #expect(
      try await service.rate(from: usd, to: aud, on: date("2024-01-20"))
        == dec("1.52"))
    #expect(
      try await service.rate(from: usd, to: aud, on: date("2024-01-31"))
        == dec("1.52"))
  }

  @Test("identity rate is 1 and pre-history throws")
  func identityAndPreHistory() async throws {
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.fiat(code: "AUD")
    let service = try makeService(["2024-01-15": ["AUD": dec("1.50")]])
    #expect(
      try await service.rate(from: usd, to: usd, on: date("2024-01-15")) == 1)
    _ = try await service.rate(from: usd, to: aud, on: date("2024-01-15"))
    await #expect(throws: (any Error).self) {
      _ = try await service.rate(from: usd, to: aud, on: self.date("2024-01-01"))
    }
  }
}
