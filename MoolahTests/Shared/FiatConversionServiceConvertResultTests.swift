import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("FiatConversionService.convertResult")
struct FiatConversionServiceConvertResultTests {
  private let usd = Instrument.USD
  private let aud = Instrument.AUD

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private func makeService(
    rates: [String: [String: Decimal]] = [:]
  ) throws -> FiatConversionService {
    let database = try ProfileDatabase.openInMemory()
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: rates), database: database)
    return FiatConversionService(exchangeRates: exchangeService)
  }

  /// Fiat-to-fiat goes through the standard `convertAmount` path and
  /// returns `.value(...)` — fiat has no `.knownZero` concept (every
  /// `.fiatCurrency` instrument has a real rate).
  @Test
  func fiatToFiatProducesValue() async throws {
    let service = try makeService(
      rates: ["2026-04-10": ["AUD": dec("1.58")]]
    )
    let amount = InstrumentAmount(quantity: dec("100"), instrument: usd)

    let result = try await service.convertResult(
      amount, to: aud, on: try date("2026-04-10"))

    #expect(result == .value(InstrumentAmount(quantity: dec("100") * dec("1.58"), instrument: aud)))
  }

  /// A non-fiat source must throw `unsupportedInstrumentKind` from the
  /// underlying `convert` — the discriminated method mirrors the
  /// throwing contract of `convertAmount` for unsupported pairs and
  /// must never collapse an unsupported pair to `.knownZero`.
  @Test
  func nonFiatSourceThrowsUnsupportedInstrumentKind() async throws {
    let service = try makeService()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let amount = InstrumentAmount(quantity: dec("1"), instrument: eth)

    await #expect(throws: ConversionError.unsupportedInstrumentKind) {
      _ = try await service.convertResult(amount, to: usd, on: try date("2026-04-10"))
    }
  }
}
