import SwiftUI

/// Top-level view that switches between loading, sign-in, and signed-in states.
struct AppRootView: View {
  @Environment(AuthStore.self) private var authStore

  var body: some View {
    switch authStore.state {
    case .loading:
      ProgressView()
        .task { await authStore.load() }
    case .signedOut:
      WelcomeView()
    case .signedIn:
      ContentView()
    }
  }
}
