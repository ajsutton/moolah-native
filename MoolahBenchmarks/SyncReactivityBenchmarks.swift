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
    // Per-iteration accumulator for the cumulative MainActor time spent
    // inside `AccountStore.apply(accounts:)`. The store's
    // `testApplyMainThreadNanos` counter is monotonic from store
    // construction; the benchmark snapshots the delta across the
    // bulk-write window and reports the worst-case across iterations
    // against the `< 50 ms` Layer 7 acceptance criterion. We track
    // worst-case (rather than average) because the criterion is a
    // ceiling, not a typical-case target — one bad iteration is the
    // user-visible cost.
    nonisolated(unsafe) var worstMainThreadNanos: UInt64 = 0
    measure(metrics: metrics, options: options) {
      // Each iteration: fresh backend, fresh store, bulk write, await
      // settle. The XCTClockMetric records the wall-clock per iteration.
      // `awaitSyncExpecting` spins the main RunLoop while the async work
      // completes — a `DispatchSemaphore.wait()` here would deadlock the
      // MainActor-isolated `AccountStore` methods (see
      // `BenchmarkHelpers.swift`).
      let iterationNanos = awaitSyncExpecting { @MainActor in
        try await Self.runOneBulkSyncIteration()
      }
      if iterationNanos > worstMainThreadNanos {
        worstMainThreadNanos = iterationNanos
      }
    }
    // Surface the worst-case MainActor time so it's visible in
    // `xcodebuild test` stdout. Format chosen so a `grep mainThreadMs`
    // pulls a single greppable line; the integer ms is what the < 50 ms
    // acceptance criterion compares against.
    let worstMs = Double(worstMainThreadNanos) / 1_000_000.0
    print(
      "mainThreadMs=\(String(format: "%.3f", worstMs)) "
        + "(worst across \(options.iterationCount) iterations, "
        + "worstNanos=\(worstMainThreadNanos))")
  }

  /// One bulk-sync iteration: build a fresh backend, attach the commit
  /// observer, seed accounts, drive an `AccountStore` through the
  /// bulk-write window, and return the cumulative MainActor nanoseconds
  /// the store spent inside `apply(accounts:)` over the bulk-sync slice.
  /// A single helper so the per-iteration teardown is trivially obvious.
  @MainActor
  private static func runOneBulkSyncIteration() async throws -> UInt64 {
    let (backend, database) = try TestBackend.create()
    // Layer 7 signpost 1: attach the GRDB-commit observer so the
    // bulk-write commit is recorded in any concurrently-captured
    // Instruments trace. Opt-in (benchmarks only) so production isn't
    // paying for instrumentation it doesn't need.
    BenchmarkGRDBCommitObserver.attach(to: database)
    let accountIds = (0..<10).map { _ in UUID() }
    TestBackend.seed(
      accounts: accountIds.map { id in
        Account(id: id, name: "A\(id)", type: .bank, instrument: .defaultTestInstrument)
      },
      in: database)
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    // Reactive path: await the initial observation tick. The store
    // subscribes via `repository.observeAll()` in `init`; the first
    // emission delivers the seeded accounts list.
    try await store.waitForFirstEmission(timeout: .seconds(10))
    // Snapshot the MainActor-time counter AFTER the initial emission
    // settles so the measured delta covers only the bulk-sync window,
    // not the seed-and-bootstrap warmup.
    let nanosBefore = store.testApplyMainThreadNanos
    // `seedBulkTransactionLegs` bundles all 50k inserts into a single
    // GRDB write so the measurement is dominated by per-row SQL
    // prepare/exec rather than commit overhead.
    try TestBackend.seedBulkTransactionLegs(
      count: 50_000, accountIds: accountIds, in: database)
    // Await a post-bulk emission. `{ _ in true }` is the right
    // predicate: each leg references one of the 10 seeded accounts so
    // `accounts.count` stays at 10; we just want any post-write tick.
    try await store.waitForNextEmission(
      matching: { _ in true },
      description: "any post-bulk emission",
      timeout: .seconds(30))
    let iterationNanos = store.testApplyMainThreadNanos &- nanosBefore
    store.stopObserving()
    return iterationNanos
  }
}
