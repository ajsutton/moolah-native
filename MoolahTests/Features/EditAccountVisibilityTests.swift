import Foundation
import Testing

@testable import Moolah

/// Pins `EditAccountView.resolvePickerVisibility(...)`. The resolver
/// is a pure async function over a closure-typed snapshot probe — it
/// owns the rule "show the Valuation picker when an investment account
/// has at least one snapshot, fail-open on transient probe error,
/// re-throw on cancellation" but knows nothing about SwiftUI or the
/// dialog's `@State`. See
/// `plans/2026-05-05-restrict-valuation-picker-design.md` §3.3 for
/// the design and §5.2 for the test-branch matrix.
@Suite("EditAccountView.resolvePickerVisibility")
struct EditAccountVisibilityTests {
  @Test("probe returns true → .shown")
  func probeReturnsTrue_returnsShown() async throws {
    let result = try await EditAccountView.resolvePickerVisibility(
      accountId: UUID(),
      snapshotProbe: { true })
    #expect(result == .shown)
  }

  @Test("probe returns false → .hidden")
  func probeReturnsFalse_returnsHidden() async throws {
    let result = try await EditAccountView.resolvePickerVisibility(
      accountId: UUID(),
      snapshotProbe: { false })
    #expect(result == .hidden)
  }

  @Test("probe throws generic error → .shownAfterFailure")
  func probeThrowsGenericError_returnsShownAfterFailure() async throws {
    struct ProbeError: Error {}
    let result = try await EditAccountView.resolvePickerVisibility(
      accountId: UUID(),
      snapshotProbe: { throw ProbeError() })
    #expect(result == .shownAfterFailure)
  }

  @Test("probe throws CancellationError → re-throws")
  func probeThrowsCancellationError_propagates() async throws {
    await #expect(throws: CancellationError.self) {
      try await EditAccountView.resolvePickerVisibility(
        accountId: UUID(),
        snapshotProbe: { throw CancellationError() })
    }
  }
}
