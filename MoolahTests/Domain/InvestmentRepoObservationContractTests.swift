import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InvestmentRepository observation contract")
struct InvestmentRepoObservationContractTests {

  // MARK: - observeValues(accountId:page:pageSize:)

  @Test("observeValues initial emission reflects current DB state")
  func observeValuesInitialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    var iterator = backend.investments
      .observeValues(accountId: accountId, page: 0, pageSize: 50)
      .makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.values.isEmpty == true)
    #expect(initial?.hasMore == false)
  }

  @Test("setValue emits updated page")
  func observeValuesEmitsOnSetValue() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    var iterator = backend.investments
      .observeValues(accountId: accountId, page: 0, pageSize: 50)
      .makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    let amount = InstrumentAmount(quantity: dec("1234.00"), instrument: .defaultTestInstrument)
    try await backend.investments.setValue(
      accountId: accountId, date: Date(), value: amount)

    let after = await iterator.next()
    #expect(after?.values.count == 1)
    #expect(after?.values.first?.value.quantity == dec("1234.00"))
  }

  @Test("no-op no second emission (removeDuplicates works)")
  func observeValuesNoReEmitOnNoOp() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    let date = Date()
    let amount = InstrumentAmount(quantity: dec("1000.00"), instrument: .defaultTestInstrument)
    try await backend.investments.setValue(accountId: accountId, date: date, value: amount)

    var iterator = backend.investments
      .observeValues(accountId: accountId, page: 0, pageSize: 50)
      .makeAsyncIterator()
    _ = await iterator.next()  // initial — single value

    // Re-write the same (accountId, date) with the same amount: this
    // does an UPDATE in the repo (the upsert path) but the column
    // values are unchanged, so the observation should not re-emit.
    try await backend.investments.setValue(accountId: accountId, date: date, value: amount)

    let receivedBox = LockedBox<Bool>(false)
    let pollTask = Task<Void, Never> { [receivedBox] in
      var localIterator = iterator
      if await localIterator.next() != nil {
        receivedBox.set(true)
      }
    }
    try? await Task.sleep(for: .milliseconds(200))
    pollTask.cancel()
    _ = await pollTask.value
    #expect(
      receivedBox.get() == false,
      "removeDuplicates failed: a no-op upsert produced a re-emission")
  }

  // MARK: - observeDailyBalances(accountId:)

  @Test("observeDailyBalances initial emission reflects current DB state")
  func observeDailyBalancesInitialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    var iterator = backend.investments
      .observeDailyBalances(accountId: accountId)
      .makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  // MARK: - observeAllValues()

  @Test("observeAllValues fires on any investment_value write")
  func observeAllValuesFiresOnWrite() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.investments.observeAllValues().makeAsyncIterator()
    _ = await iterator.next()  // initial tick

    let amount = InstrumentAmount(quantity: dec("500.00"), instrument: .defaultTestInstrument)
    try await backend.investments.setValue(
      accountId: UUID(), date: Date(), value: amount)

    let after: Void? = await iterator.next()
    #expect(after != nil, "expected a tick after investment_value write")
  }

  // MARK: - observeErrors()

  @Test("observeErrors stays quiet on a healthy repository")
  func observeErrorsOnHealthyRepository() async throws {
    let (backend, _) = try TestBackend.create()
    let stream = backend.investments.observeErrors()
    let pollTask = Task<(any Error)?, Never> {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(100))
    pollTask.cancel()
    let surfaced = await pollTask.value
    #expect(surfaced == nil)
  }
}
