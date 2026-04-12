import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("InvestmentStore")
@MainActor
struct InvestmentStoreTests {

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
  }

  private func makeValues(accountId: UUID, count: Int) -> [UUID: [InvestmentValue]] {
    let values = (0..<count).map { i in
      InvestmentValue(
        date: Calendar.current.date(byAdding: .day, value: -i, to: Date())!,
        value: MonetaryAmount(cents: 100_000 + (i * 1000), currency: Currency.defaultTestCurrency)
      )
    }
    return [accountId: values]
  }

  @Test("Load values populates values array")
  func testLoadValues() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 3), in: container,
    )
    let store = InvestmentStore(repository: backend.investments)

    await store.loadValues(accountId: accountId)

    #expect(store.values.count == 3)
    #expect(store.isLoading == false)
    #expect(store.error == nil)
  }

  @Test("Load values with reset clears existing values")
  func testLoadValuesReset() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 5), in: container,
    )
    let store = InvestmentStore(repository: backend.investments)

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 5)

    // Reset with new empty account
    await store.loadValues(accountId: UUID())
    #expect(store.values.isEmpty)
  }

  @Test("Set value adds to list and re-sorts")
  func testSetValue() async throws {
    let accountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(repository: backend.investments)

    let date = makeDate(year: 2024, month: 3, day: 15)
    let amount = MonetaryAmount(cents: 125_000_00, currency: Currency.defaultTestCurrency)

    await store.setValue(accountId: accountId, date: date, value: amount)

    #expect(store.values.count == 1)
    #expect(store.values[0].date == date)
    #expect(store.values[0].value.cents == 125_000_00)
  }

  @Test("Set value upserts existing date")
  func testSetValueUpserts() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency))
      ]
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: container)
    let store = InvestmentStore(repository: backend.investments)

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    let newAmount = MonetaryAmount(cents: 200_000, currency: Currency.defaultTestCurrency)
    await store.setValue(accountId: accountId, date: date, value: newAmount)

    #expect(store.values.count == 1)
    #expect(store.values[0].value.cents == 200_000)
  }

  @Test("Remove value removes from list")
  func testRemoveValue() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency))
      ]
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: container)
    let store = InvestmentStore(repository: backend.investments)

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    await store.removeValue(accountId: accountId, date: date)
    #expect(store.values.isEmpty)
  }

  @Test("Remove value handles error gracefully")
  func testRemoveNonExistent() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(repository: backend.investments)

    await store.removeValue(accountId: UUID(), date: Date())

    #expect(store.error != nil)
  }

  // MARK: - Daily Balances

  @Test("Load daily balances populates dailyBalances array")
  func testLoadDailyBalances() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(), type: .income, date: makeDate(year: 2024, month: 1, day: 1),
          accountId: accountId,
          amount: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency)),
        Transaction(
          id: UUID(), type: .income, date: makeDate(year: 2024, month: 2, day: 1),
          accountId: accountId,
          amount: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency)),
      ], in: container)

    let store = InvestmentStore(repository: backend.investments)
    await store.loadDailyBalances(accountId: accountId)

    #expect(store.dailyBalances.count == 2)
    #expect(store.dailyBalances[0].balance.cents == 100_000)
    #expect(store.dailyBalances[1].balance.cents == 200_000)
  }

  // MARK: - Filtered Data

  @Test("Filtered values returns all values when period is .all")
  func testFilteredValuesAll() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 3), in: container,
    )
    let store = InvestmentStore(repository: backend.investments)

    await store.loadValues(accountId: accountId)
    store.selectedPeriod = .all

    #expect(store.filteredValues.count == 3)
  }

  // MARK: - Chart Data Merging

  @Test("Chart data points merge values and balances by date")
  func testChartDataPointsMerge() {
    let date1 = makeDate(year: 2024, month: 1, day: 1)
    let date2 = makeDate(year: 2024, month: 2, day: 1)

    let values = [
      InvestmentValue(
        date: date2,
        value: MonetaryAmount(cents: 120_000, currency: Currency.defaultTestCurrency)),
      InvestmentValue(
        date: date1,
        value: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency)),
    ]

    let balances = [
      AccountDailyBalance(
        date: date1,
        balance: MonetaryAmount(cents: 90_000, currency: Currency.defaultTestCurrency)),
      AccountDailyBalance(
        date: date2,
        balance: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency)),
    ]

    let result = mergeChartData(values: values, balances: balances, period: .all)

    #expect(result.count == 2)
    #expect(result[0].value == 100_000)
    #expect(result[0].balance == 90_000)
    #expect(result[0].profitLoss == 10_000)
    #expect(result[1].value == 120_000)
    #expect(result[1].balance == 100_000)
    #expect(result[1].profitLoss == 20_000)
  }

  @Test("Chart data points forward-fill missing values")
  func testChartDataPointsForwardFill() {
    let date1 = makeDate(year: 2024, month: 1, day: 1)
    let date2 = makeDate(year: 2024, month: 2, day: 1)
    let date3 = makeDate(year: 2024, month: 3, day: 1)

    // Value only on date1 and date3; balance only on date1 and date2
    let values = [
      InvestmentValue(
        date: date3,
        value: MonetaryAmount(cents: 130_000, currency: Currency.defaultTestCurrency)),
      InvestmentValue(
        date: date1,
        value: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency)),
    ]

    let balances = [
      AccountDailyBalance(
        date: date1,
        balance: MonetaryAmount(cents: 90_000, currency: Currency.defaultTestCurrency)),
      AccountDailyBalance(
        date: date2,
        balance: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency)),
    ]

    let result = mergeChartData(values: values, balances: balances, period: .all)

    #expect(result.count == 3)
    // date1: both present
    #expect(result[0].value == 100_000)
    #expect(result[0].balance == 90_000)
    // date2: value forward-filled from date1
    #expect(result[1].value == 100_000)
    #expect(result[1].balance == 100_000)
    // date3: balance forward-filled from date2
    #expect(result[2].value == 130_000)
    #expect(result[2].balance == 100_000)
  }

  @Test("Chart data points with period filter includes pre-period anchor")
  func testChartDataPointsPeriodFilter() {
    // Use dates relative to "now" for period filtering
    let now = Date()
    let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: now)!
    let threeMonthsAgo = Calendar.current.date(byAdding: .month, value: -3, to: now)!
    let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: now)!

    let values = [
      InvestmentValue(
        date: now,
        value: MonetaryAmount(cents: 150_000, currency: Currency.defaultTestCurrency)),
      InvestmentValue(
        date: oneMonthAgo,
        value: MonetaryAmount(cents: 130_000, currency: Currency.defaultTestCurrency)),
      InvestmentValue(
        date: sixMonthsAgo,
        value: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency)),
    ]

    let balances = [
      AccountDailyBalance(
        date: sixMonthsAgo,
        balance: MonetaryAmount(cents: 80_000, currency: Currency.defaultTestCurrency)),
      AccountDailyBalance(
        date: threeMonthsAgo,
        balance: MonetaryAmount(cents: 90_000, currency: Currency.defaultTestCurrency)),
      AccountDailyBalance(
        date: now,
        balance: MonetaryAmount(cents: 100_000, currency: Currency.defaultTestCurrency)),
    ]

    // Filter to 3 months: should include threeMonthsAgo and now,
    // plus pre-period anchors from sixMonthsAgo
    let result = mergeChartData(values: values, balances: balances, period: .months(3))

    // Should have data points, and the pre-period value should be anchored
    #expect(result.count >= 2)
  }

  @Test("Empty data produces empty chart data points")
  func testChartDataPointsEmpty() {
    let result = mergeChartData(values: [], balances: [], period: .all)
    #expect(result.isEmpty)
  }
}
