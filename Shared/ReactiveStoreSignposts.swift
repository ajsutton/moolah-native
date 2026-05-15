// Shared/ReactiveStoreSignposts.swift

import Foundation
import os.signpost

// File-scope helpers used by every reactive store's Layer 7 signpost /
// main-thread-time instrumentation. Shared so each store's
// `+Signposts.swift` companion file doesn't duplicate the same helper.
//
// Pairs with `Shared/Signposts.swift`, which declares the
// `Signposts.reactiveStore` `OSLog` consumed by `withReactiveStoreSignpost`.

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
/// keyed by `name`. Returns whatever `body` returns. Used by every
/// reactive store's apply / recompute paths so the call sites stay one
/// line each instead of three (signpost-id, `.begin`, `.end`).
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
