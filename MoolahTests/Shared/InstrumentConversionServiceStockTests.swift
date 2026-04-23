import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentConversionService — Stock")
struct InstrumentConversionServiceStockTests {
  let aud = Instrument.fiat(code: "AUD")
  let usd = Instrument.fiat(code: "USD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")

  private func makeService(
    stockPrices: [String: StockPriceResponse] = [:],
    exchangeRates: [String: [String: Decimal]] = [:]
  ) -> FullConversionService {
    let stockClient = FixedStockPriceClient(responses: stockPrices)
    let stockCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("stock-price-tests")
      .appendingPathComponent(UUID().uuidString)
    let stockService = StockPriceService(client: stockClient, cacheDirectory: stockCacheDir)
    let rateClient = FixedRateClient(rates: exchangeRates)
    let rateCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("conversion-stock-tests")
      .appendingPathComponent(UUID().uuidString)
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: rateCacheDir)
    return FullConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )
  }

  private func dateString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }

  @Test
  func stockToListingCurrencySameFiat() async throws {
    // BHP listed in AUD, converting to AUD — just stock price, no FX
    let today = Date()
    let ds = dateString(today)
    let service = makeService(
      stockPrices: [
        "BHP.AX": StockPriceResponse(instrument: .AUD, prices: [ds: Decimal(string: "42.30")!])
      ]
    )

    let result = try await service.convert(Decimal(150), from: bhp, to: aud, on: today)
    // 150 shares * $42.30 = $6345.00
    #expect(result == Decimal(string: "6345.00")!)
  }

  @Test
  func stockToForeignFiatRequiresFXConversion() async throws {
    // AAPL listed in USD, converting to AUD — stock price * FX rate
    let today = Date()
    let ds = dateString(today)
    let service = makeService(
      stockPrices: [
        "AAPL": StockPriceResponse(instrument: .USD, prices: [ds: Decimal(string: "185.50")!])
      ],
      exchangeRates: [ds: ["AUD": Decimal(string: "1.55")!]]  // 1 USD = 1.55 AUD
    )

    let result = try await service.convert(Decimal(10), from: aapl, to: aud, on: today)
    // 10 shares * $185.50 USD * 1.55 AUD/USD = $2875.25 AUD
    #expect(result == Decimal(string: "2875.25")!)
  }

  @Test
  func stockToStockNotSupported() async throws {
    // Stock-to-stock conversion should throw (go through fiat as intermediate)
    let today = Date()
    let service = makeService()

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(10), from: bhp, to: aapl, on: today)
    }
  }

  @Test
  func fiatToStockNotSupported() async throws {
    // Fiat-to-stock conversion doesn't make sense for display purposes
    let today = Date()
    let service = makeService()

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(1000), from: aud, to: bhp, on: today)
    }
  }

  @Test
  func foreignFiatToStockListedInDifferentFiatThrowsSymmetrically() async throws {
    // fiatToStock is not a supported conversion direction regardless of source fiat.
    let today = Date()
    let service = makeService()

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(1000), from: usd, to: bhp, on: today)
    }
  }

  @Test
  func stockInNonPrimaryFiatConvertsViaIntermediate() async throws {
    // Simulate a USD-listed stock converting to USD directly (no FX required).
    let today = Date()
    let ds = dateString(today)
    let service = makeService(
      stockPrices: [
        "AAPL": StockPriceResponse(instrument: .USD, prices: [ds: Decimal(string: "185.50")!])
      ]
    )

    let result = try await service.convert(Decimal(10), from: aapl, to: usd, on: today)
    #expect(result == Decimal(string: "1855.00")!)
  }

  @Test
  func zeroDecimalFiatToStockAlsoRejected() async throws {
    // JPY has 0 decimals; request still throws (direction not supported) without crashing.
    let today = Date()
    let jpy = Instrument.fiat(code: "JPY")
    let service = makeService()

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(100000), from: jpy, to: bhp, on: today)
    }
  }

  @Test
  func stockPriceFetchFailureThrows() async throws {
    let today = Date()
    let stockClient = FixedStockPriceClient(shouldFail: true)
    let stockCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("stock-price-fail-tests")
      .appendingPathComponent(UUID().uuidString)
    let stockService = StockPriceService(client: stockClient, cacheDirectory: stockCacheDir)
    let rateClient = FixedRateClient(rates: [:])
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("conversion-stock-tests")
      .appendingPathComponent(UUID().uuidString)
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: cacheDir)
    let service = FullConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(10), from: bhp, to: aud, on: today)
    }
  }

  /// Scheduled transactions and forecast days carry future dates. The
  /// FullConversionService must clamp those to today so the fiat-to-fiat
  /// branch resolves against the latest available rate rather than
  /// throwing `noRateAvailable` for a future date with no cached rate.
  @Test("FullConversionService clamps future dates to today (fiat→fiat)")
  func clampsFutureDatesToToday() async throws {
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: Date())
    let pastKey = dateString(calendar.date(byAdding: .day, value: -10, to: today)!)
    let service = makeService(
      exchangeRates: [pastKey: ["USD": Decimal(string: "0.6500")!]]
    )

    let future = calendar.date(byAdding: .day, value: 30, to: today)!
    let result = try await service.convert(Decimal(1000), from: aud, to: usd, on: future)
    #expect(result == Decimal(650))
  }
}
