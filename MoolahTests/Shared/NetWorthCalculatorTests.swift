import Foundation
import Testing

@testable import Moolah

@Suite("NetWorthCalculator")
struct NetWorthCalculatorTests {
  let profileCurrency = Instrument.fiat(code: "AUD")
  let usd = Instrument.fiat(code: "USD")

  @Test func singleCurrencyMatchingProfile_noPriceLookupsNeeded() async throws {
    let accountId = UUID()
    let legs = [
      makeLeg(accountId: accountId, instrument: profileCurrency, quantity: 1000, date: day(0)),
      makeLeg(accountId: accountId, instrument: profileCurrency, quantity: 500, date: day(1)),
    ]
    let calculator = NetWorthCalculator(
      profileCurrency: profileCurrency,
      conversionService: FixedConversionService()
    )
    let points = try await calculator.compute(
      legs: legs,
      dateRange: day(0)...day(1)
    )
    #expect(points.count == 2)
    #expect(points.last?.value == InstrumentAmount(quantity: 1500, instrument: profileCurrency))
  }

  @Test func multiCurrency_convertsToProfileCurrency() async throws {
    let accountId = UUID()
    let legs = [
      makeLeg(accountId: accountId, instrument: usd, quantity: 100, date: day(0))
    ]
    // Fixed rate: 1 USD = 1.5 AUD
    let service = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let calculator = NetWorthCalculator(
      profileCurrency: profileCurrency,
      conversionService: service
    )
    let points = try await calculator.compute(
      legs: legs,
      dateRange: day(0)...day(0)
    )
    #expect(points.count == 1)
    #expect(points[0].value == InstrumentAmount(quantity: 150, instrument: profileCurrency))
  }

  @Test func emptyLegs_returnsEmptyPoints() async throws {
    let calculator = NetWorthCalculator(
      profileCurrency: profileCurrency,
      conversionService: FixedConversionService()
    )
    let points = try await calculator.compute(legs: [], dateRange: day(0)...day(5))
    #expect(points.isEmpty)
  }

  @Test func multipleInstruments_summedPerDay() async throws {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let legs = [
      makeLeg(accountId: accountId, instrument: profileCurrency, quantity: 1000, date: day(0)),
      makeLeg(accountId: accountId, instrument: bhp, quantity: 10, date: day(0)),
    ]
    // BHP rate: 1 share = 50 AUD
    let service = FixedConversionService(rates: ["ASX:BHP": 50])
    let calculator = NetWorthCalculator(
      profileCurrency: profileCurrency,
      conversionService: service
    )
    let points = try await calculator.compute(
      legs: legs,
      dateRange: day(0)...day(0)
    )
    #expect(points.count == 1)
    // 1000 AUD + (10 shares * 50 AUD) = 1500
    #expect(points[0].value == InstrumentAmount(quantity: 1500, instrument: profileCurrency))
  }

  @Test func cumulativePositions_acrossMultipleDays() async throws {
    let accountId = UUID()
    let legs = [
      makeLeg(accountId: accountId, instrument: profileCurrency, quantity: 1000, date: day(0)),
      makeLeg(accountId: accountId, instrument: profileCurrency, quantity: 200, date: day(2)),
    ]
    let calculator = NetWorthCalculator(
      profileCurrency: profileCurrency,
      conversionService: FixedConversionService()
    )
    let points = try await calculator.compute(
      legs: legs,
      dateRange: day(0)...day(5)
    )
    #expect(points.count == 2)
    #expect(points[0].value.quantity == 1000)
    #expect(points[1].value.quantity == 1200)
  }

  // MARK: - Helpers

  private func day(_ offset: Int) -> Date {
    Calendar(identifier: .gregorian).date(
      byAdding: .day, value: offset,
      to: Calendar(identifier: .gregorian).startOfDay(for: Date())
    )!
  }

  private func makeLeg(
    accountId: UUID, instrument: Instrument, quantity: Decimal, date: Date
  ) -> DatedLeg {
    DatedLeg(
      leg: TransactionLeg(
        accountId: accountId,
        instrument: instrument,
        quantity: quantity,
        type: .income,
        categoryId: nil,
        earmarkId: nil
      ),
      date: date
    )
  }
}
