import SwiftUI

extension View {
  /// Injects both a `ProfileStore` and a `ProfileSession` into the view
  /// hierarchy for `#Preview` use. Required by any view that uses
  /// `.profileNavigationTitle(...)` — that modifier reads both from
  /// `@Environment` and crashes if either is missing.
  ///
  /// Defaults to no-profile preview environments. Pass an explicit
  /// `profileStore` (e.g. `ProfileStore.preview(profiles: [fixture])`)
  /// to exercise the multi-profile branch of `profileNavigationTitle`.
  @MainActor
  func previewProfileEnvironment(
    session: ProfileSession? = nil,
    profileStore: ProfileStore = ProfileStore.preview()
  ) -> some View {
    let resolvedSession: ProfileSession
    if let session {
      resolvedSession = session
    } else {
      // In-memory preview session can't fail in practice: opens an
      // ephemeral GRDB queue with no disk access. A trap here is
      // acceptable in #Preview.
      // swiftlint:disable:next force_try
      resolvedSession = try! ProfileSession.preview()
    }
    return
      self
      .environment(profileStore)
      .environment(resolvedSession)
  }
}
