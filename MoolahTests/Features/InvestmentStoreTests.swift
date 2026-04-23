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
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

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
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

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
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

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
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    let newAmount = InstrumentAmount(
      quantity: Decimal(string: "2000.00")!, instrument: .defaultTestInstrument)
    await store.setValue(accountId: accountId, date: date, value: newAmount)

    #expect(store.values.count == 1)
    #expect(store.values[0].value.quantity == Decimal(string: "2000.00")!)
  }

  @Test("Set value upserts in-memory when dates have different times on same day")
  func testSetValueUpsertsInMemoryWithDifferentTimes() async throws {
    let accountId = UUID()
    let morning = Calendar.current.date(
      from: DateComponents(year: 2024, month: 3, day: 15, hour: 9, minute: 0))!
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: morning,
          value: InstrumentAmount(
            quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument))
      ]
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: container)
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    let evening = Calendar.current.date(
      from: DateComponents(year: 2024, month: 3, day: 15, hour: 18, minute: 30))!
    let newAmount = InstrumentAmount(
      quantity: Decimal(string: "2000.00")!, instrument: .defaultTestInstrument)
    await store.setValue(accountId: accountId, date: evening, value: newAmount)

    #expect(store.values.count == 1, "Expected upsert but got duplicate entries in store")
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
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    await store.removeValue(accountId: accountId, date: date)
    #expect(store.values.isEmpty)
  }

  @Test("Remove value handles error gracefully")
  func testRemoveNonExistent() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

    await store.removeValue(accountId: UUID(), date: Date())

    #expect(store.error != nil)
  }

  // MARK: - onInvestmentValueChanged callback

  @Test("Set value fires onInvestmentValueChanged with latest value")
  func testSetValueFiresCallback() async throws {
    let accountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())

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
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())
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
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())
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
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FixedConversionService())
    await store.loadValues(accountId: accountId)

    var receivedValue: InstrumentAmount?? = .none
    store.onInvestmentValueChanged = { _, value in
      receivedValue = value
    }

    await store.removeValue(accountId: accountId, date: date)

    #expect(receivedValue == .some(nil))
  }

  // MARK: - Daily Balances
}
