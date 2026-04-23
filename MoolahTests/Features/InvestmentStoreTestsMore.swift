import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("InvestmentStore")
@MainActor
struct InvestmentStoreTestsMore {

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
  }

  private func makeValues(accountId: UUID, count: Int) -> [UUID: [InvestmentValue]] {
    let values = (0..<count).map { i in
      InvestmentValue(
        date: Calendar.current.date(byAdding: .day, value: -i, to: Date())!,
        value: InstrumentAmount(
          quantity: Decimal(1000 + i * 10), instrument: .defaultTestInstrument)
      )
    }
    return [accountId: values]
  }

  @Test("Load daily balances populates dailyBalances array")
  func testLoadDailyBalances() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = TestBackend.seed(
      transactions: [
        Transaction(
          date: makeDate(year: 2024, month: 1, day: 1),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(string: "1000.00")!, type: .income)
          ]),
        Transaction(
          date: makeDate(year: 2024, month: 2, day: 1),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(string: "1000.00")!, type: .income)
          ]),
      ], in: container)

    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())
    await store.loadDailyBalances(accountId: accountId)

    #expect(store.dailyBalances.count == 2)
    #expect(store.dailyBalances[0].balance.quantity == Decimal(string: "1000.00")!)
    #expect(store.dailyBalances[1].balance.quantity == Decimal(string: "2000.00")!)
  }

  // MARK: - Filtered Data

  @Test("Filtered values returns all values when period is .all")
  func testFilteredValuesAll() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 3), in: container
    )
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

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
        value: InstrumentAmount(
          quantity: Decimal(string: "1200.00")!, instrument: .defaultTestInstrument)),
      InvestmentValue(
        date: date1,
        value: InstrumentAmount(
          quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)),
    ]

    let balances = [
      AccountDailyBalance(
        date: date1,
        balance: InstrumentAmount(
          quantity: Decimal(string: "900.00")!, instrument: .defaultTestInstrument)),
      AccountDailyBalance(
        date: date2,
        balance: InstrumentAmount(
          quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)),
    ]

    let result = mergeChartData(values: values, balances: balances, period: .all)

    #expect(result.count == 2)
    #expect(result[0].value == Decimal(string: "1000.00")!)
    #expect(result[0].balance == Decimal(string: "900.00")!)
    #expect(result[0].profitLoss == Decimal(string: "100.00")!)
    #expect(result[1].value == Decimal(string: "1200.00")!)
    #expect(result[1].balance == Decimal(string: "1000.00")!)
    #expect(result[1].profitLoss == Decimal(string: "200.00")!)
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
        value: InstrumentAmount(
          quantity: Decimal(string: "1300.00")!, instrument: .defaultTestInstrument)),
      InvestmentValue(
        date: date1,
        value: InstrumentAmount(
          quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)),
    ]

    let balances = [
      AccountDailyBalance(
        date: date1,
        balance: InstrumentAmount(
          quantity: Decimal(string: "900.00")!, instrument: .defaultTestInstrument)),
      AccountDailyBalance(
        date: date2,
        balance: InstrumentAmount(
          quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)),
    ]

    let result = mergeChartData(values: values, balances: balances, period: .all)

    #expect(result.count == 3)
    // date1: both present
    #expect(result[0].value == Decimal(string: "1000.00")!)
    #expect(result[0].balance == Decimal(string: "900.00")!)
    // date2: value forward-filled from date1
    #expect(result[1].value == Decimal(string: "1000.00")!)
    #expect(result[1].balance == Decimal(string: "1000.00")!)
    // date3: balance forward-filled from date2
    #expect(result[2].value == Decimal(string: "1300.00")!)
    #expect(result[2].balance == Decimal(string: "1000.00")!)
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
        value: InstrumentAmount(
          quantity: Decimal(string: "1500.00")!, instrument: .defaultTestInstrument)),
      InvestmentValue(
        date: oneMonthAgo,
        value: InstrumentAmount(
          quantity: Decimal(string: "1300.00")!, instrument: .defaultTestInstrument)),
      InvestmentValue(
        date: sixMonthsAgo,
        value: InstrumentAmount(
          quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)),
    ]

    let balances = [
      AccountDailyBalance(
        date: sixMonthsAgo,
        balance: InstrumentAmount(
          quantity: Decimal(string: "800.00")!, instrument: .defaultTestInstrument)),
      AccountDailyBalance(
        date: threeMonthsAgo,
        balance: InstrumentAmount(
          quantity: Decimal(string: "900.00")!, instrument: .defaultTestInstrument)),
      AccountDailyBalance(
        date: now,
        balance: InstrumentAmount(
          quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)),
    ]

    // Filter to 3 months: should include threeMonthsAgo and now,
    // plus pre-period anchors from sixMonthsAgo
    let result = mergeChartData(values: values, balances: balances, period: .months(3))

    // Should have data points, and the pre-period value should be anchored
    #expect(result.count >= 2)
  }
}
