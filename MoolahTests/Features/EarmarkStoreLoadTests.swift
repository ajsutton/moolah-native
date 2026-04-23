import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Load")
@MainActor
struct EarmarkStoreLoadTests {
  @Test
  func testPopulatesFromRepository() async throws {
    let earmark = Earmark(name: "Holiday Fund", instrument: Instrument.defaultTestInstrument)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seedWithTransactions(
      earmarks: [earmark],
      amounts: [earmark.id: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "Holiday Fund")
  }

  @Test
  func testSortingByPosition() async throws {
    let higher = Earmark(name: "E1", instrument: Instrument.defaultTestInstrument, position: 2)
    let lower = Earmark(name: "E2", instrument: Instrument.defaultTestInstrument, position: 1)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seedWithTransactions(
      earmarks: [higher, lower],
      amounts: [
        higher.id: (saved: 100, spent: 0),
        lower.id: (saved: 200, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].name == "E2")
    #expect(store.earmarks[1].name == "E1")
  }

  @Test
  func testEarmarkInstrumentSetCorrectly() async throws {
    let holiday = Earmark(name: "Holiday", instrument: Instrument.defaultTestInstrument)
    let carRepair = Earmark(name: "Car Repair", instrument: Instrument.defaultTestInstrument)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [holiday, carRepair],
      amounts: [
        holiday.id: (saved: 500, spent: 0),
        carRepair.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].instrument == Instrument.defaultTestInstrument)
    #expect(store.earmarks[1].instrument == Instrument.defaultTestInstrument)
  }
}
