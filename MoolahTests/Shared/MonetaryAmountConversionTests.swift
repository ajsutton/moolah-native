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

  @Test func convertedDelegatesToService() async throws {
    let client = FixedRateClient(rates: [
      "2026-04-11": ["GBP": Decimal(string: "0.497")!]
    ])
    let service = ExchangeRateService(client: client)
    let amount = InstrumentAmount(quantity: Decimal(string: "200.00")!, instrument: .AUD)

    let result = try await service.convert(
      amount, to: Instrument.fiat(code: "GBP"), on: date("2026-04-11"))

    #expect(result.quantity == Decimal(string: "99.40")!)
    #expect(result.instrument.id == "GBP")
  }

  @Test func convertedSameInstrumentReturnsOriginal() async throws {
    let client = FixedRateClient()
    let service = ExchangeRateService(client: client)
    let amount = InstrumentAmount(quantity: Decimal(string: "123.45")!, instrument: .AUD)

    let result = try await service.convert(amount, to: .AUD, on: date("2026-04-11"))

    #expect(result.quantity == Decimal(string: "123.45")!)
    #expect(result.instrument == .AUD)
  }
}
