import Foundation
import os.lock

/// Per-test breadcrumb of every driver action that ran, in order, with `✓`
/// (success) or `✗` (failure) marks. Written to `trace.txt` in the failure
/// artefact directory by `MoolahUITestCase.tearDown` when a test fails.
///
/// Usage from a driver action method's first line:
///   Trace.record(#function)
/// Or, with detail:
///   Trace.record(#function, detail: "account=\(account)")
///
/// Outcome marks are appended automatically by `record(_:)` when the action
/// returns; failure cases call `recordFailure(...)` from the assertion path.
public enum Trace {
  // os.OSAllocatedUnfairLock is Sendable on macOS 13+; appropriate here
  // because the trace is potentially read on the test thread (during
  // tearDown) while drivers running on the main thread append to it.
  // swiftlint:disable:next legacy_objc_type
  private static let lock = OSAllocatedUnfairLock<State>(initialState: .init())

  private struct State {
    var lines: [String] = []
    var pending: String?  // most recent action, awaiting an outcome mark
  }

  /// Records the start of a driver action. The `function` argument is
  /// usually `#function`; `detail` carries any context worth surfacing in
  /// the trace (e.g. the symbolic argument the action received).
  ///
  /// Marks any previous pending action as `✓` (success) under the
  /// convention that returning from one action means the next one is now
  /// underway. The terminal action is marked `✓` by `tearDown` on test
  /// success and `✗` by `recordFailure` on assertion failure.
  public static func record(_ function: String = #function, detail: String? = nil) {
    let entry: String
    if let detail {
      entry = "\(function) — \(detail)"
    } else {
      entry = function
    }
    lock.withLock { state in
      if let pending = state.pending {
        state.lines.append("✓ \(pending)")
      }
      state.pending = entry
    }
  }

  /// Marks the most recent action with `✗` and a short reason. Called from
  /// `XCTFail` paths inside drivers and from `MoolahUITestCase.tearDown`
  /// when the test ended in failure without an explicit driver fail.
  ///
  /// Expectation methods (`expect…`) on drivers also call this when an
  /// assertion fails — the failure is attributed to the most recent
  /// *action* in the trace (which is the `pending` line). This is
  /// intentional: the action's post-condition is what the expectation
  /// checks, so a failed expectation typically points back at the action
  /// that should have established the post-condition.
  public static func recordFailure(_ reason: String) {
    lock.withLock { state in
      if let pending = state.pending {
        state.lines.append("✗ \(pending) — FAILED: \(reason)")
        state.pending = nil
      } else {
        state.lines.append("✗ (no pending action) — FAILED: \(reason)")
      }
    }
  }

  /// Renders the recorded breadcrumb for the failure artefact. If the most
  /// recent action is still pending and the test is being torn down on a
  /// successful path, mark it `✓`; if torn down on failure, mark it `✗`.
  public static func render(succeeded: Bool) -> String {
    let lines: [String] = lock.withLock { state in
      var rendered = state.lines
      if let pending = state.pending {
        rendered.append(succeeded ? "✓ \(pending)" : "✗ \(pending) — FAILED")
      }
      return rendered
    }
    if lines.isEmpty {
      return "(no driver actions recorded)\n"
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Resets the trace between tests. Called from `MoolahUITestCase.setUp`.
  public static func reset() {
    lock.withLock { state in
      state.lines.removeAll()
      state.pending = nil
    }
  }
}
