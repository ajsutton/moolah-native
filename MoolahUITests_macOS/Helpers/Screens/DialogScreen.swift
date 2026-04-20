import XCTest

/// Driver scaffold for system dialogs — error alerts, delete
/// confirmations, etc. Returned from `MoolahApp.dialogs`.
///
/// Currently a stub awaiting the first test that needs to interact with a
/// dialog. Extend by adding action methods (each starting with
/// `Trace.record(#function)` and waiting on a real post-condition) and
/// expectation methods (`expect…`, read-only). See
/// `guides/UI_TEST_GUIDE.md` §7.
@MainActor
struct DialogScreen {
  let app: MoolahApp
}
