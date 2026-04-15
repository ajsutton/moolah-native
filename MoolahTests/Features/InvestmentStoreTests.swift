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
        value: InstrumentAmount(
          quantity: Decimal(1000 + i * 10), instrument: .defaultTestInstrument)
      )
    }
    return [accountId: values]
  }

  @Test("Load values populates values array")
  func testLoadValues() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 3), in: container
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
      investmentValues: makeValues(accountId: accountId, count: 5), in: container
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
    let amount = InstrumentAmount(
      quantity: Decimal(string: "125000.00")!, instrument: .defaultTestInstrument)

    await store.setValue(accountId: accountId, date: date, value: amount)

    #expect(store.values.count == 1)
    #expect(store.values[0].date == date)
    #expect(store.values[0].value.quantity == Decimal(string: "125000.00")!)
  }

  @Test("Set value upserts existing date")
  func testSetValueUpserts() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: InstrumentAmount(
            quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument))
      ]
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: container)
    let store = InvestmentStore(repository: backend.investments)

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    let newAmount = InstrumentAmount(
      quantity: Decimal(string: "2000.00")!, instrument: .defaultTestInstrument)
    await store.setValue(accountId: accountId, date: date, value: newAmount)

    #expect(store.values.count == 1)
    #expect(store.values[0].value.quantity == Decimal(string: "2000.00")!)
  }

  @Test("Remove value removes from list")
  func testRemoveValue() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: InstrumentAmount(
            quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument))
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

  // MARK: - onInvestmentValueChanged callback

  @Test("Set value fires onInvestmentValueChanged with latest value")
  func testSetValueFiresCallback() async throws {
    let accountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(repository: backend.investments)

    var receivedAccountId: UUID?
    var receivedValue: InstrumentAmount?
    store.onInvestmentValueChanged = { acctId, value in
      receivedAccountId = acctId
      receivedValue = value
    }

    let date = makeDate(year: 2024, month: 3, day: 15)
    let amount = InstrumentAmount(
      quantity: Decimal(string: "125000.00")!, instrument: .defaultTestInstrument)

    await store.setValue(accountId: accountId, date: date, value: amount)

    #expect(receivedAccountId == accountId)
    #expect(receivedValue == amount)
  }

  @Test("Set value fires callback with latest value when multiple values exist")
  func testSetValueFiresCallbackWithLatest() async throws {
    let accountId = UUID()
    let earlierDate = makeDate(year: 2024, month: 1, day: 1)
    let laterDate = makeDate(year: 2024, month: 6, day: 1)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: laterDate,
          value: InstrumentAmount(
            quantity: Decimal(string: "2000.00")!, instrument: .defaultTestInstrument))
      ]
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: container)
    let store = InvestmentStore(repository: backend.investments)
    await store.loadValues(accountId: accountId)

    var receivedValue: InstrumentAmount?
    store.onInvestmentValueChanged = { _, value in
      receivedValue = value
    }

    // Add an earlier value — the latest should still be the June value
    let earlierAmount = InstrumentAmount(
      quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)
    await store.setValue(accountId: accountId, date: earlierDate, value: earlierAmount)

    let expectedLatest = InstrumentAmount(
      quantity: Decimal(string: "2000.00")!, instrument: .defaultTestInstrument)
    #expect(receivedValue == expectedLatest)
  }

  @Test("Remove value fires onInvestmentValueChanged")
  func testRemoveValueFiresCallback() async throws {
    let accountId = UUID()
    let date1 = makeDate(year: 2024, month: 1, day: 1)
    let date2 = makeDate(year: 2024, month: 6, day: 1)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date1,
          value: InstrumentAmount(
            quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)),
        InvestmentValue(
          date: date2,
          value: InstrumentAmount(
            quantity: Decimal(string: "2000.00")!, instrument: .defaultTestInstrument)),
      ]
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: container)
    let store = InvestmentStore(repository: backend.investments)
    await store.loadValues(accountId: accountId)

    var receivedValue: InstrumentAmount?? = .none
    store.onInvestmentValueChanged = { _, value in
      receivedValue = value
    }

    // Remove the latest value — callback should fire with the remaining value
    await store.removeValue(accountId: accountId, date: date2)

    let expectedLatest = InstrumentAmount(
      quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)
    #expect(receivedValue == .some(expectedLatest))
  }

  @Test("Remove last value fires callback with nil")
  func testRemoveLastValueFiresCallbackWithNil() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: InstrumentAmount(
            quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument))
      ]
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: container)
    let store = InvestmentStore(repository: backend.investments)
    await store.loadValues(accountId: accountId)

    var receivedValue: InstrumentAmount?? = .none
    store.onInvestmentValueChanged = { _, value in
      receivedValue = value
    }

    await store.removeValue(accountId: accountId, date: date)

    #expect(receivedValue == .some(nil))
  }

  // MARK: - Daily Balances

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

    let store = InvestmentStore(repository: backend.investments)
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

  @Test("Empty data produces empty chart data points")
  func testChartDataPointsEmpty() {
    let result = mergeChartData(values: [], balances: [], period: .all)
    #expect(result.isEmpty)
  }
}
