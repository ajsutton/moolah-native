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
  /// Drives the apply path through TestBackend's GRDB queue, then waits
  /// for the AccountStore to settle.
  ///
  /// Uses `measure(metrics:)` with `XCTClockMetric` and `XCTMemoryMetric`
  /// so wall-clock and peak-memory are surfaced in `xcresult` and
  /// Instruments rather than swallowed in stdout.
  /// Per `guides/BENCHMARKING_GUIDE.md` rules 1 and 2.
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
        await store.load()  // legacy path; replaced with waitForFirstEmission in commit 6

        // Use `TestBackend.seedBulkTransactionLegs` (the new helper added
        // alongside this benchmark) for the 50k-leg bulk write. The
        // helper bundles all inserts into a single GRDB write so the
        // measurement is dominated by per-row SQL prepare/exec cost
        // rather than transaction-commit overhead.
        try TestBackend.seedBulkTransactionLegs(
          count: 50_000,
          accountIds: accountIds,
          in: database
        )
        // Drive a single notification through the legacy path (commit 2
        // only). For the reactive path (commits 6, 15) this is replaced
        // with `try await store.waitForNextEmission(...)`.
        await store.reloadFromSync()
      }
    }
  }
}
