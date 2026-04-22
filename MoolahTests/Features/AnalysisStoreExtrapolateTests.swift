import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — extrapolateBalances")
struct AnalysisStoreExtrapolateTests {

  private let calendar = Calendar.current

  private func date(_ daysFromToday: Int, relativeTo today: Date = Date()) throws -> Date {
    let offset = try #require(
      calendar.date(byAdding: .day, value: daysFromToday, to: today))
    return calendar.startOfDay(for: offset)
  }

  private func balance(
    daysFromToday: Int,
    quantity: Decimal = Decimal(10),
    isForecast: Bool = false,
    relativeTo today: Date = Date()
  ) throws -> DailyBalance {
    let amount = InstrumentAmount(quantity: quantity, instrument: .defaultTestInstrument)
    if isForecast {
      return DailyBalance(
        date: try date(daysFromToday, relativeTo: today),
        balance: amount,
        earmarked: .zero(instrument: .defaultTestInstrument),
        availableFunds: amount,
        investments: .zero(instrument: .defaultTestInstrument),
        investmentValue: nil,
        netWorth: amount,
        bestFit: nil,
        isForecast: true
      )
    }
    return DailyBalance(
      date: try date(daysFromToday, relativeTo: today),
      balance: amount,
      earmarked: .zero(instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
      investmentValue: nil
    )
  }

  @Test func emptyBalancesReturnsEmpty() {
    let result = AnalysisStore.extrapolateBalances([], today: Date(), forecastUntil: nil)
    #expect(result.isEmpty)
  }

  @Test func extendsActualBalancesToToday() throws {
    let today = calendar.startOfDay(for: Date())
    let balances = [try balance(daysFromToday: -5, relativeTo: today)]

    let result = AnalysisStore.extrapolateBalances(balances, today: today, forecastUntil: nil)

    #expect(result.count == 2)
    #expect(calendar.startOfDay(for: result[0].date) == (try date(-5, relativeTo: today)))
    #expect(calendar.startOfDay(for: result[1].date) == today)
    #expect(result[1].balance.quantity == result[0].balance.quantity)
    #expect(!result[1].isForecast)
  }

  @Test func doesNotExtendIfActualAlreadyAtToday() throws {
    let today = calendar.startOfDay(for: Date())
    let balances = [try balance(daysFromToday: 0, relativeTo: today)]

    let result = AnalysisStore.extrapolateBalances(balances, today: today, forecastUntil: nil)

    #expect(result.count == 1)
  }

  @Test func extendsForecastBackToToday() throws {
    let today = calendar.startOfDay(for: Date())
    let balances = [
      try balance(daysFromToday: -3, quantity: Decimal(10), relativeTo: today),
      try balance(
        daysFromToday: 5, quantity: Decimal(15), isForecast: true, relativeTo: today),
    ]

    let forecastUntil = try date(30, relativeTo: today)
    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    // Forecast should be extended back to today using the last actual balance
    #expect(forecasts.count >= 2)
    #expect(calendar.startOfDay(for: forecasts[0].date) == today)
    #expect(forecasts[0].balance.quantity == Decimal(10))  // Last actual balance value
  }

  @Test func extendsForecastToEndDate() throws {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = try date(30, relativeTo: today)
    let balances = [
      try balance(daysFromToday: -3, quantity: Decimal(10), relativeTo: today),
      try balance(
        daysFromToday: 5, quantity: Decimal(15), isForecast: true, relativeTo: today),
    ]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    let lastForecast = try #require(forecasts.last)
    #expect(calendar.startOfDay(for: lastForecast.date) == forecastUntil)
    #expect(lastForecast.balance.quantity == Decimal(15))
  }

  @Test func noForecastDataSkipsForecastExtension() throws {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = try date(30, relativeTo: today)
    let balances = [
      try balance(daysFromToday: -3, quantity: Decimal(10), relativeTo: today)
    ]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    #expect(forecasts.isEmpty)
  }

  @Test func resultIsSortedByDate() throws {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = try date(30, relativeTo: today)
    let balances = [
      try balance(daysFromToday: -10, quantity: Decimal(8), relativeTo: today),
      try balance(daysFromToday: -3, quantity: Decimal(10), relativeTo: today),
      try balance(
        daysFromToday: 5, quantity: Decimal(15), isForecast: true, relativeTo: today),
      try balance(
        daysFromToday: 15, quantity: Decimal(12), isForecast: true, relativeTo: today),
    ]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    for i in 1..<result.count {
      #expect(result[i].date >= result[i - 1].date)
    }
  }
}
