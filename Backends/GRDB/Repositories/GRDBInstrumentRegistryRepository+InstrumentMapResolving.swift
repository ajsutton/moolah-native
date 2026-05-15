// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+InstrumentMapResolving.swift

import GRDB
import os

extension GRDBInstrumentRegistryRepository: InstrumentMapResolving {
  /// Returns the memoised `[String: Instrument]` snapshot, rebuilding it
  /// from the database only when a mutation has invalidated the cache.
  ///
  /// The cutover routes every per-profile instrument resolution through
  /// this single shared method on the serial profile-index queue (shared
  /// across all profiles, the price caches, and sync apply). A per-call
  /// `database.read` + full-map rebuild (incl. ~150 `Instrument.fiat`
  /// constructions) on the cold-launch burst (~1400 calls/sec) would
  /// serialise on that queue and regress badly. Steady state here is a
  /// cached dictionary read behind one unfair-lock acquisition — cheaper
  /// than today's per-call per-profile fetch.
  ///
  /// Stored rows first, ambient ISO fiat supplemented after — preserving
  /// the ordering callers will see post-cutover so no read path changes
  /// behaviour when it switches from per-profile to shared resolution.
  /// **Stale-read safety (bounded loop, not recursion).** The cold path
  /// captures the invalidation generation, drops the lock, then
  /// `await`s `database.read`. On commit it only adopts the rebuilt
  /// snapshot if the generation is unchanged. If a mutation landed
  /// during the await the generation moved on, the snapshot is *not*
  /// committed, and — critically — this method does **not** return that
  /// now-stale read. Instead it loops: the next iteration either finds a
  /// fresh valid snapshot another caller committed in the meantime (and
  /// returns it) or re-reads against the post-mutation database state.
  ///
  /// Termination: mutations never call `instrumentMap()`, so the loop
  /// races only other readers and committed writes. Each iteration
  /// either returns or observes a strictly greater generation; the
  /// generation is monotone and a read is admitted by GRDB's serial
  /// writer only after the write that bumped it has committed, so after
  /// a bounded number of iterations a read sees the settled
  /// post-mutation state and commits. The lock is never held across the
  /// `await` (the read is issued with the lock released and re-acquired
  /// only to inspect/commit) — preserve that.
  func instrumentMap() async throws -> [String: Instrument] {
    while true {
      let snapshotRead = mapCache.withLock { state in
        InstrumentMapSnapshotRead(
          snapshot: state.snapshot,
          isValid: state.isValid,
          generation: state.generation)
      }
      if snapshotRead.isValid {
        return snapshotRead.snapshot
      }
      let generationAtRead = snapshotRead.generation

      // Cold / post-invalidation path: rebuild from the database. The
      // signpost interval makes a regression here (a missed-invalidation
      // rebuild storm, or the rebuild itself getting slow) attributable
      // in Instruments under the `Repository` category.
      let rebuilt = try await readInstrumentMapWithSignpost()

      let committed = mapCache.withLock { state -> Bool in
        state.dbReadCount += 1
        // Only commit the rebuilt snapshot if no mutation invalidated
        // the cache while the async `database.read` was in flight. If
        // one did, the generation moved on; leave `isValid == false` and
        // report not-committed so the caller re-loops rather than
        // returning this now-stale read.
        guard state.generation == generationAtRead else { return false }
        state.snapshot = rebuilt
        state.isValid = true
        return true
      }
      if committed {
        return rebuilt
      }
      // A mutation landed during the await; the rebuilt read is stale.
      // Loop again: re-check the cache (a fresh valid snapshot may now
      // exist) and otherwise re-read against the post-mutation state.
    }
  }

  /// Reads the full instrument map from the database wrapped in the
  /// `InstrumentRegistry.instrumentMap.rebuild` os_signpost interval so
  /// a missed-invalidation rebuild storm is attributable in Instruments
  /// under the `Repository` category.
  private func readInstrumentMapWithSignpost() async throws -> [String: Instrument] {
    let log = Signposts.repository
    let name: StaticString = "InstrumentRegistry.instrumentMap.rebuild"
    let signpostID = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: name, signpostID: signpostID)
    defer { os_signpost(.end, log: log, name: name, signpostID: signpostID) }
    return try await database.read { database in
      try InstrumentRow.fetchInstrumentMap(database: database)
    }
  }
}

/// A consistent read of the memoised cache taken under a single lock
/// acquisition: the snapshot itself, whether it is still valid, and the
/// invalidation generation at the moment of the read. Named (rather than
/// a tuple with an optional-collection member) so the lock closure's
/// return type stays SwiftLint-clean and the validity check reads as a
/// plain boolean at the call site.
private struct InstrumentMapSnapshotRead {
  let snapshot: [String: Instrument]
  let isValid: Bool
  let generation: Int
}
