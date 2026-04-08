import Foundation
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
        value: MonetaryAmount(cents: 100_000 + (i * 1000), currency: Currency.defaultCurrency)
      )
    }
    return [accountId: values]
  }

  @Test("Load values populates values array")
  func testLoadValues() async {
    let accountId = UUID()
    let repo = InMemoryInvestmentRepository(
      initialValues: makeValues(accountId: accountId, count: 3))
    let store = InvestmentStore(repository: repo)

    await store.loadValues(accountId: accountId, reset: true)

    #expect(store.values.count == 3)
    #expect(store.isLoading == false)
    #expect(store.error == nil)
  }

  @Test("Load values with reset clears existing values")
  func testLoadValuesReset() async {
    let accountId = UUID()
    let repo = InMemoryInvestmentRepository(
      initialValues: makeValues(accountId: accountId, count: 5))
    let store = InvestmentStore(repository: repo)

    await store.loadValues(accountId: accountId, reset: true)
    #expect(store.values.count == 5)

    // Reset with new empty account
    await store.loadValues(accountId: UUID(), reset: true)
    #expect(store.values.isEmpty)
  }

  @Test("Set value adds to list and re-sorts")
  func testSetValue() async {
    let accountId = UUID()
    let repo = InMemoryInvestmentRepository()
    let store = InvestmentStore(repository: repo)

    let date = makeDate(year: 2024, month: 3, day: 15)
    let amount = MonetaryAmount(cents: 125_000_00, currency: Currency.defaultCurrency)

    await store.setValue(accountId: accountId, date: date, value: amount)

    #expect(store.values.count == 1)
    #expect(store.values[0].date == date)
    #expect(store.values[0].value.cents == 125_000_00)
  }

  @Test("Set value upserts existing date")
  func testSetValueUpserts() async {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: MonetaryAmount(cents: 100_000, currency: Currency.defaultCurrency))
      ]
    ]
    let repo = InMemoryInvestmentRepository(initialValues: initialValues)
    let store = InvestmentStore(repository: repo)

    await store.loadValues(accountId: accountId, reset: true)
    #expect(store.values.count == 1)

    let newAmount = MonetaryAmount(cents: 200_000, currency: Currency.defaultCurrency)
    await store.setValue(accountId: accountId, date: date, value: newAmount)

    #expect(store.values.count == 1)
    #expect(store.values[0].value.cents == 200_000)
  }

  @Test("Remove value removes from list")
  func testRemoveValue() async {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: MonetaryAmount(cents: 100_000, currency: Currency.defaultCurrency))
      ]
    ]
    let repo = InMemoryInvestmentRepository(initialValues: initialValues)
    let store = InvestmentStore(repository: repo)

    await store.loadValues(accountId: accountId, reset: true)
    #expect(store.values.count == 1)

    await store.removeValue(accountId: accountId, date: date)
    #expect(store.values.isEmpty)
  }

  @Test("Remove value handles error gracefully")
  func testRemoveNonExistent() async {
    let repo = InMemoryInvestmentRepository()
    let store = InvestmentStore(repository: repo)

    await store.removeValue(accountId: UUID(), date: Date())

    #expect(store.error != nil)
  }
}
