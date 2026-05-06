// Features/Accounts/AccountStore+Signposts.swift

import Foundation
import os.signpost

// File-scope helpers used by the Layer 7 signpost / main-thread-time
// instrumentation in `AccountStore`. Lives in a companion file so the
// helpers do not push `AccountStore.swift` past SwiftLint's
// `file_length` warning threshold (400 lines), and so future reactive
// stores (Earmark, Transaction, …) can adopt the same primitives.
//
// See `plans/2026-05-06-reactive-sync-refresh-design.md` Section 2
// Layer 7 and `guides/BENCHMARKING_GUIDE.md` "Adding Signposts".

/// Wall-clock nanoseconds elapsed since `start`. Truncates sub-ns
/// precision (fine — benchmark thresholds are in ms) and saturates
/// against (theoretical, infeasible) multi-decade overflow.
func nanoseconds(since start: ContinuousClock.Instant) -> UInt64 {
  let elapsed = ContinuousClock.now - start
  let (seconds, attoseconds) = elapsed.components
  return UInt64(max(0, seconds)) &* 1_000_000_000
    &+ UInt64(max(0, attoseconds / 1_000_000_000))
}

/// Wraps `body` in a `Signposts.reactiveStore` `.begin` / `.end` pair
/// keyed by `name`. Returns whatever `body` returns. Used by the
/// reactive store apply / recompute paths so the call sites stay one
/// line each instead of three (signpost-id, `.begin`, `.end`) — keeps
/// `AccountStore.swift` under SwiftLint's `file_length` ceiling.
@discardableResult
@MainActor
func withReactiveStoreSignpost<T>(
  _ name: StaticString,
  _ body: @MainActor () async -> T
) async -> T {
  let log = Signposts.reactiveStore
  let spid = OSSignpostID(log: log)
  os_signpost(.begin, log: log, name: name, signpostID: spid)
  defer { os_signpost(.end, log: log, name: name, signpostID: spid) }
  return await body()
}
