import Foundation
import GRDB
import XCTest

@testable import Moolah

/// Benchmarks the cost of sync-driven UI refresh.
///
/// Intent: capture three numbers per implementation (legacy / reactive /
/// reactive + mitigations) so we can decide which mitigations from the
/// design's toolbox are warranted.
///
/// Numbers we care about:
/// - **emissions:** how many store updates fire during a 50k-record sync.
/// - **mainThreadMs:** cumulative MainActor time consumed by store updates.
/// - **wallClockMs:** total time from sync-apply start to last emission.
///
/// Run via `just benchmark SyncReactivityBenchmarks`.
final class SyncReactivityBenchmarks: XCTestCase {

  /// 50k transactions delivered as one CKSyncEngine fetch session.
  /// Drives the reactive apply path through TestBackend's GRDB observation
  /// stream, then waits for the AccountStore to settle via
  /// `waitForNextEmission`.
  ///
  /// Uses `measure(metrics:)` with `XCTClockMetric` and `XCTMemoryMetric`
  /// so wall-clock and peak-memory are surfaced in `xcresult` and
  /// Instruments rather than swallowed in stdout.
  /// Per `guides/BENCHMARKING_GUIDE.md` rules 1 and 2.
  ///
  /// Reactive path (Stage 6): the store now subscribes to GRDB's
  /// `observeAll()` stream from `init`; `waitForFirstEmission()` awaits the
  /// initial population tick and `waitForNextEmission(matching:)` awaits the
  /// tick driven by the post-bulk GRDB write. No `load()` /
  /// `reloadFromSync()` calls — both were removed in Stage 5.
  func testBulkSyncRefresh() {
    let metrics: [any XCTMetric] = [XCTClockMetric(), XCTMemoryMetric()]
    let options = XCTMeasureOptions()
    options.iterationCount = 10
    measure(metrics: metrics, options: options) {
      // Each iteration: fresh backend, fresh store, bulk write, await
      // settle. The XCTClockMetric records the wall-clock per iteration.
      // `awaitSyncExpecting` spins the main RunLoop while the async work
      // completes — a `DispatchSemaphore.wait()` here would deadlock the
      // MainActor-isolated `AccountStore` methods (see
      // `BenchmarkHelpers.swift`).
      awaitSyncExpecting { @MainActor in
        let (backend, database) = try TestBackend.create()
        let accountIds = (0..<10).map { _ in UUID() }
        TestBackend.seed(
          accounts: accountIds.map { id in
            Account(
              id: id, name: "A\(id)", type: .bank,
              instrument: .defaultTestInstrument)
          },
          in: database
        )
        let store = AccountStore(
          repository: backend.accounts,
          conversionService: backend.conversionService,
          targetInstrument: .defaultTestInstrument
        )
        // Reactive path: await the initial observation tick. The store
        // subscribes via `repository.observeAll()` in `init`; the first
        // emission delivers the seeded accounts list.
        try await store.waitForFirstEmission(timeout: .seconds(10))

        // Use `TestBackend.seedBulkTransactionLegs` (the new helper added
        // alongside this benchmark) for the 50k-leg bulk write. The
        // helper bundles all inserts into a single GRDB write so the
        // measurement is dominated by per-row SQL prepare/exec cost
        // rather than transaction-commit overhead.
        let preWriteCount = store.accounts.ordered.count
        try TestBackend.seedBulkTransactionLegs(
          count: 50_000,
          accountIds: accountIds,
          in: database
        )
        // Reactive path: await a post-bulk emission. The GRDB observation
        // inside the backend fires after the write commits and delivers a
        // fresh accounts snapshot. The predicate checks that the store has
        // consumed that snapshot — positions on the seeded accounts grow
        // because each leg references one of the 10 seeded accounts, so
        // `accounts.count` stays the same but we wait for any emission
        // after the write completes. A generous 30s timeout gives the
        // GRDB observation pipeline ample time even under Simulator load.
        // Using `!= preWriteCount` would be fragile (count stays at 10);
        // `{ _ in true }` on any post-write tick is the correct measure
        // of "store settled" for position-only changes.
        _ = preWriteCount  // suppress unused-variable warning
        try await store.waitForNextEmission(
          matching: { _ in true },
          description: "any post-bulk emission",
          timeout: .seconds(30)
        )
        store.stopObserving()
      }
    }
  }
}
