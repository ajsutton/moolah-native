import SwiftUI

/// Injects all stores from a ProfileSession into the environment, then shows AppRootView.
/// The `.id(session.id)` forces a full view hierarchy rebuild on profile switch.
struct SessionRootView: View {
  let session: ProfileSession

  var body: some View {
    AppRootView()
      .id(session.id)
      .environment(session)
      .environment(session.authStore)
      .environment(session.accountStore)
      .environment(session.transactionStore)
      .environment(session.categoryStore)
      .environment(session.earmarkStore)
      .environment(session.analysisStore)
      .environment(session.investmentStore)
      .environment(session.tradeStore)
      .focusedValue(\.authStore, session.authStore)
      .focusedValue(\.activeProfileSession, session)
  }
}
