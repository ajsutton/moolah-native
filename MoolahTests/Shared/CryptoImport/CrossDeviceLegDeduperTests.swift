// MoolahTests/Shared/CryptoImport/CrossDeviceLegDeduperTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `CrossDeviceLegDeduper`. The deduper runs after
/// every CKSyncEngine `fetchedRecordZoneChanges` callback to collapse
/// cross-device duplicate `TransactionLeg` rows into one canonical leg
/// per `(accountId, externalId)` group. Tests use `TestBackend`
/// (`CloudKitBackend` + in-memory GRDB) so the dedup pass exercises the
/// real `delete(id:)` plumbing that propagates back through CKSyncEngine,
/// not a mock.
///
/// Shared fixtures (`Setup`, `makeLeg`, ids, `permutations`) live in
/// `CrossDeviceLegDeduperTestSupport.swift`. Determinism / mixed-leg
/// cases live in `CrossDeviceLegDeduperEdgeCaseTests.swift`.
@Suite("CrossDeviceLegDeduper — convergence")
@MainActor
struct CrossDeviceLegDeduperTests {
  private typealias Support = CrossDeviceLegDeduperTestSupport

  @Test("Two transactions sharing (accountId, externalId) collapse to the lower-UUID survivor")
  func twoDeviceRaceConverges() async throws {
    let setup = try Support.makeSetup()
    setup.seedAccount(Support.accountA)
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnA, accountId: Support.accountA, externalId: Support.hash))
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnB, accountId: Support.accountA, externalId: Support.hash))

    let recording = RecordingTransactionRepository(wrapping: setup.backend.transactions)
    let deduper = CrossDeviceLegDeduper(transactions: recording)

    let collapsed = try await deduper.dedup(touchedExternalIds: [Support.hash])

    #expect(collapsed == 1)
    let stored = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(stored.map(\.id) == [Support.txnA])
    let recordedDeletes = await recording.deletedIds
    #expect(recordedDeletes == [Support.txnB])
  }

  @Test("Both devices' deduper independently reach the same canonical winner")
  func bothDevicesConvergeToSameCanonical() async throws {
    let setupDeviceA = try Support.makeSetup()
    let setupDeviceB = try Support.makeSetup()
    for setup in [setupDeviceA, setupDeviceB] {
      setup.seedAccount(Support.accountA)
      try await setup.create(
        Support.makeSingleLegTransaction(
          id: Support.txnA, accountId: Support.accountA, externalId: Support.hash))
      try await setup.create(
        Support.makeSingleLegTransaction(
          id: Support.txnB, accountId: Support.accountA, externalId: Support.hash))
    }

    let dedupedA = CrossDeviceLegDeduper(transactions: setupDeviceA.backend.transactions)
    let dedupedB = CrossDeviceLegDeduper(transactions: setupDeviceB.backend.transactions)

    _ = try await dedupedA.dedup(touchedExternalIds: [Support.hash])
    _ = try await dedupedB.dedup(touchedExternalIds: [Support.hash])

    let storedA = try await setupDeviceA.backend.transactions.fetchAll(filter: .init())
    let storedB = try await setupDeviceB.backend.transactions.fetchAll(filter: .init())
    #expect(storedA.map(\.id) == [Support.txnA])
    #expect(storedB.map(\.id) == [Support.txnA])
  }

  @Test("Idempotent: running again on a converged state is a no-op")
  func idempotentOnConvergedState() async throws {
    let setup = try Support.makeSetup()
    setup.seedAccount(Support.accountA)
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnA, accountId: Support.accountA, externalId: Support.hash))

    let deduper = CrossDeviceLegDeduper(transactions: setup.backend.transactions)
    let firstRun = try await deduper.dedup(touchedExternalIds: [Support.hash])
    let secondRun = try await deduper.dedup(touchedExternalIds: [Support.hash])

    #expect(firstRun == 0)
    #expect(secondRun == 0)
    let stored = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(stored.count == 1)
  }

  @Test("Touched set excluding the duplicate's externalId leaves the duplicate in place")
  func touchedSetScopingSkipsUnrelatedDuplicates() async throws {
    let setup = try Support.makeSetup()
    setup.seedAccount(Support.accountA)
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnA, accountId: Support.accountA, externalId: Support.hash))
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnB, accountId: Support.accountA, externalId: Support.hash))

    let deduper = CrossDeviceLegDeduper(transactions: setup.backend.transactions)
    let collapsed = try await deduper.dedup(touchedExternalIds: ["0xunrelated"])

    #expect(collapsed == 0)
    let stored = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(stored.count == 2)
  }

  @Test("Empty touched set is a no-op (no DB query)")
  func emptyTouchedSetIsNoOp() async throws {
    let setup = try Support.makeSetup()
    setup.seedAccount(Support.accountA)
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnA, accountId: Support.accountA, externalId: Support.hash))
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnB, accountId: Support.accountA, externalId: Support.hash))

    let deduper = CrossDeviceLegDeduper(transactions: setup.backend.transactions)
    let collapsed = try await deduper.dedup(touchedExternalIds: [])

    #expect(collapsed == 0)
    let stored = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(stored.count == 2)
  }

  @Test("Deletes route through TransactionRepository.delete(id:), not directly to GRDB")
  func deletesRouteThroughRepository() async throws {
    let setup = try Support.makeSetup()
    setup.seedAccount(Support.accountA)
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnA, accountId: Support.accountA, externalId: Support.hash))
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnB, accountId: Support.accountA, externalId: Support.hash))

    let recording = RecordingTransactionRepository(wrapping: setup.backend.transactions)
    let deduper = CrossDeviceLegDeduper(transactions: recording)
    _ = try await deduper.dedup(touchedExternalIds: [Support.hash])

    let recordedDeletes = await recording.deletedIds
    #expect(recordedDeletes == [Support.txnB])
    // Cross-check: the underlying database is in lock-step (the
    // recording wrapper forwards `delete(id:)` to the GRDB repo, so a
    // bypass would leave the DB out of sync with the recorded count).
    let stored = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(stored.count == 1)
  }
}
