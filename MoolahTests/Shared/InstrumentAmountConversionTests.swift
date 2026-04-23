// MoolahTests/Shared/InstrumentAmountConversionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentAmount Conversion")
struct InstrumentAmountConversionTests {
  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  @Test
  func convertedDelegatesToService() async throws {
    let client = FixedRateClient(rates: [
      "2026-04-11": ["GBP": dec("0.497")]
    ])
    let service = ExchangeRateService(client: client)
    let amount = InstrumentAmount(quantity: dec("200.00"), instrument: .AUD)

    let result = try await service.convert(
      amount, to: Instrument.fiat(code: "GBP"), on: date("2026-04-11"))

    #expect(result.quantity == dec("99.40"))
    #expect(result.instrument.id == "GBP")
  }

  @Test
  func convertedSameInstrumentReturnsOriginal() async throws {
    let client = FixedRateClient()
    let service = ExchangeRateService(client: client)
    let amount = InstrumentAmount(quantity: dec("123.45"), instrument: .AUD)

    let result = try await service.convert(amount, to: .AUD, on: date("2026-04-11"))

    #expect(result.quantity == dec("123.45"))
    #expect(result.instrument == .AUD)
  }

  @Test
  func convertZeroDecimalFiatPreservesPrecision() async throws {
    // JPY has 0 decimals; converting yields a multiplied quantity with normal Decimal precision.
    let client = FixedRateClient(rates: [
      "2026-04-11": ["JPY": dec("95.50")]
    ])
    let service = ExchangeRateService(client: client)
    let amount = InstrumentAmount(quantity: Decimal(100), instrument: .AUD)

    let result = try await service.convert(
      amount, to: Instrument.fiat(code: "JPY"), on: date("2026-04-11"))

    #expect(result.quantity == Decimal(9550))
    #expect(result.instrument.id == "JPY")
  }

  @Test
  func convertRespectsSourceQuantitySign() async throws {
    let client = FixedRateClient(rates: [
      "2026-04-11": ["USD": dec("0.65")]
    ])
    let service = ExchangeRateService(client: client)
    let amount = InstrumentAmount(quantity: dec("-200.00"), instrument: .AUD)

    let result = try await service.convert(
      amount, to: .USD, on: date("2026-04-11"))

    #expect(result.quantity == dec("-130.00"))
    #expect(result.isNegative)
  }
}
