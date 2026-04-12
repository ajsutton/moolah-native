import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentConversionService")
struct InstrumentConversionServiceTests {
  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  private func makeService(
    rates: [String: [String: Decimal]] = [:]
  ) -> FiatConversionService {
    let client = FixedRateClient(rates: rates)
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("conversion-tests")
      .appendingPathComponent(UUID().uuidString)
    let exchangeRates = ExchangeRateService(client: client, cacheDirectory: cacheDir)
    return FiatConversionService(exchangeRates: exchangeRates)
  }

  @Test func sameCurrencyReturnsIdentity() async throws {
    let service = makeService()
    let result = try await service.convert(
      Decimal(string: "100.00")!,
      from: .AUD, to: .AUD,
      on: date("2025-06-15")
    )
    #expect(result == Decimal(string: "100.00")!)
  }

  @Test func convertsAUDtoUSD() async throws {
    let service = makeService(rates: [
      "2025-06-15": ["USD": Decimal(string: "0.6500")!]
    ])
    let result = try await service.convert(
      Decimal(string: "1000.00")!,
      from: .AUD, to: .USD,
      on: date("2025-06-15")
    )
    #expect(result == Decimal(string: "650.00")!)
  }

  @Test func convertsUSDtoAUD() async throws {
    let service = makeService(rates: [
      "2025-06-15": ["AUD": Decimal(string: "1.5385")!]
    ])
    let result = try await service.convert(
      Decimal(string: "650.00")!,
      from: .USD, to: .AUD,
      on: date("2025-06-15")
    )
    #expect(result == Decimal(string: "650.00")! * Decimal(string: "1.5385")!)
  }

  @Test func convertAmount() async throws {
    let service = makeService(rates: [
      "2025-06-15": ["USD": Decimal(string: "0.6500")!]
    ])
    let amount = InstrumentAmount(
      quantity: Decimal(string: "1000.00")!,
      instrument: .AUD
    )
    let result = try await service.convertAmount(
      amount, to: .USD, on: date("2025-06-15")
    )
    #expect(result.instrument == .USD)
    #expect(result.quantity == Decimal(string: "650.00")!)
  }

  @Test func convertAmountSameCurrency() async throws {
    let service = makeService()
    let amount = InstrumentAmount(
      quantity: Decimal(string: "1000.00")!,
      instrument: .AUD
    )
    let result = try await service.convertAmount(
      amount, to: .AUD, on: date("2025-06-15")
    )
    #expect(result == amount)
  }
}
