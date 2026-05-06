import Foundation
import GRDB
import Testing

@testable import Moolah

/// Symptom-A regression coverage for the reactive `AccountStore`.
///
/// "Symptom A" is the bug that motivated the reactive-sync-refresh
/// rewrite (commit 5 of `plans/2026-05-06-reactive-sync-refresh-implementation.md`):
/// when CloudKit delivered a remote sync write, the sidebar would not
/// refresh until the user pulled-to-refresh. The reactive
/// `AccountStore` subscribes to `repository.observeAll()` and
/// `conversionService.observeRates()` from `init`, so any GRDB write —
/// local OR sync-driven — propagates to the sidebar without a manual
/// reload. These tests pin that contract.
@Suite("AccountStore sync refresh", .serialized)
@MainActor
struct AccountStoreSyncRefreshTests {

  @Test("remote account insert refreshes the store without manual refresh")
  func remoteAccountInsertRefreshesStore() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    #expect(store.accounts.ordered.isEmpty)

    _ = try await backend.accounts.create(
      Account(name: "Synced", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )

    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "accounts.count == 1"
    )
    #expect(store.accounts.ordered.first?.name == "Synced")
  }

  @Test(
    "rate-tick triggers convertedTotal recompute even when accounts unchanged",
    arguments: ["exchange_rate", "stock_price", "crypto_price"]
  )
  func convertedTotalRecomputesOnRateTick(table: String) async throws {
    // CRITICAL: this test MUST use the real GRDBInstrumentConversionService
    // (the one TestBackend.create() wires up — `FiatConversionService`
    // backed by the in-memory GRDB queue). Substituting `FixedConversionService`
    // or any other test double makes the test vacuous: the stub's
    // observeRates() is a no-op AsyncStream that cannot signal a
    // cache-table write, so the test would pass for the wrong reason
    // (an unrelated emission from the account observation) and would
    // not catch a regression to the empty-table region inference bug.
    let (backend, database) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()

    // Write into the named cache table using a SQL literal helper from
    // `MoolahTests/Domain/ConversionObservationContractTests.swift`.
    // The follow-up `notifyRateCacheChange(_:)` is required for
    // WITHOUT ROWID tables — without it the SQLite update hook never
    // fires and the observation hangs (see
    // `Backends/GRDB/Observation/RateCacheTable.swift`).
    try await database.write { connection in
      switch table {
      case "exchange_rate":
        try connection.execute(literal: insertExchangeRateFixture())
        try connection.notifyRateCacheChange(.exchangeRate)
      case "stock_price":
        try connection.execute(literal: insertStockPriceFixture())
        try connection.notifyRateCacheChange(.stockPrice)
      case "crypto_price":
        try connection.execute(literal: insertCryptoPriceFixture())
        try connection.notifyRateCacheChange(.cryptoPrice)
      default:
        Issue.record("unknown table \(table)")
      }
    }

    try await store.waitForNextEmission(
      matching: { _ in true },
      description: "any emission post-rate-write to \(table)",
      timeout: .seconds(2)
    )
  }

  @Test("stopObserving cancels the observation task")
  func stopObservingCancelsObservationTask() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    // Drain any ticks buffered between init and the first
    // `waitForFirstEmission` so the post-cancel assertion only sees
    // ticks that arrive AFTER the backend write.
    await store.drainPendingEmissions()
    store.stopObserving()

    _ = try await backend.accounts.create(
      Account(name: "After cancel", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("GRDB wipes during sign-out reach the store before stopObserving cancels it")
  func signOutTeardownOrdering() async throws {
    let (backend, database) = try TestBackend.create()
    _ = try await backend.accounts.create(
      Account(name: "WillBeWiped", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "store sees seeded account"
    )

    // Simulate the sign-out path: GRDB wipes happen first, then
    // `stopObserving()` cancels the observation. The wipe-emission
    // must reach the store BEFORE cancellation, otherwise the user
    // would see the last-known-populated state frozen on screen until
    // they switched profiles or relaunched.
    try await database.write { connection in
      try connection.execute(sql: "DELETE FROM account")
    }
    try await store.waitForNextEmission(
      matching: { $0.accounts.ordered.isEmpty },
      description: "wipe propagated to store before cancellation",
      timeout: .seconds(2)
    )
    store.stopObserving()
    #expect(store.accounts.ordered.isEmpty)
  }
}
