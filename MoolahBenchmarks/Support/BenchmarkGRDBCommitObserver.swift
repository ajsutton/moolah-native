import Foundation
import GRDB
import os.signpost

@testable import Moolah

/// `TransactionObserver` that emits a one-shot `os_signpost(.event, …)`
/// in the `GRDBWrite` category each time the database commits a write.
/// Marks the moment a change becomes observable to `ValueObservation` —
/// this is signpost 1 in the four-point Layer 7 instrumentation defined
/// by `plans/2026-05-06-reactive-sync-refresh-design.md`.
///
/// Lives in the benchmarks support tree (not in `Backends/GRDB/`) so the
/// production binary never carries the observer; only benchmarks (and
/// any future ad-hoc Instruments runs that opt in) attach it. The
/// observer keeps no state beyond a counter exposed for assertions; the
/// per-commit body is a single `os_signpost(.event, …)` call.
///
/// **Lifetime.** Pass `extent: .observerLifetime` (default) and retain
/// the observer for as long as the benchmark needs commits traced. GRDB
/// holds a strong reference once `add(transactionObserver:)` is called,
/// so the observer survives until the database queue is deallocated.
final class BenchmarkGRDBCommitObserver: TransactionObserver, @unchecked Sendable {

  /// Atomically-incremented counter so benchmarks can assert "this
  /// write actually committed". The benchmarks don't read it today; it
  /// exists to make `BenchmarkGRDBCommitObserver` non-trivially
  /// testable if a future change moves the signpost emission off the
  /// commit hook.
  private let commitCount = OSAllocatedUnfairLock<Int>(initialState: 0)

  /// Number of commits observed since attach. Read on any thread.
  var observedCommits: Int { commitCount.withLock { $0 } }

  /// Tracks every change so `databaseDidCommit` is invoked. Returning
  /// `false` would skip the observer for that change kind; we want
  /// every commit, regardless of which table changed.
  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
    true
  }

  /// No-op — we don't care about per-row events, only commit boundaries.
  func databaseDidChange(with event: DatabaseEvent) {}

  /// Emits the `GRDBWrite` signpost event marking the commit point.
  /// Per `BENCHMARKING_GUIDE.md` "What NOT to signpost", a single
  /// `os_signpost(.event, …)` is the cheapest possible shape — no
  /// `.begin/.end` pair, no metadata format string.
  func databaseDidCommit(_ database: Database) {
    commitCount.withLock { $0 += 1 }
    os_signpost(.event, log: Signposts.grdbWrite, name: "grdb-commit")
  }

  func databaseDidRollback(_ database: Database) {}

  /// Convenience for benchmarks: builds an observer, attaches it to the
  /// queue with `.observerLifetime` extent, and returns the observer so
  /// the caller can read `observedCommits` if needed. The observer is
  /// retained by GRDB internally for the lifetime of the queue (or
  /// until removed via `database.remove(transactionObserver:)`), so
  /// the returned reference can be discarded if the benchmark only
  /// cares about the signpost stream.
  ///
  /// Marked `nonisolated` so it can be invoked from the synchronous
  /// `awaitSyncExpecting` setup blocks the benchmarks use.
  @discardableResult
  static func attach(to database: any DatabaseWriter) -> BenchmarkGRDBCommitObserver {
    let observer = BenchmarkGRDBCommitObserver()
    database.add(transactionObserver: observer, extent: .observerLifetime)
    return observer
  }
}
