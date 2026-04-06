import SwiftUI

/// Shown when the user is signed out.
/// The "Sign in with Google" button is hidden when requiresExplicitSignIn is false
/// (e.g. a future CloudKit backend that authenticates implicitly via Apple ID).
struct WelcomeView: View {
  @Environment(AuthStore.self) private var authStore

  var body: some View {
    VStack(spacing: 32) {
      VStack(spacing: 8) {
        Text("Moolah")
          .font(.largeTitle.bold())
        Text(String(localized: "Personal finance, your way."))
          .foregroundStyle(.secondary)
      }

      if authStore.requiresSignIn {
        Button {
          Task { await authStore.signIn() }
        } label: {
          Label(
            String(localized: "Sign in with Google"),
            systemImage: "person.crop.circle.badge.checkmark"
          )
          .frame(maxWidth: 280)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }

      if let message = authStore.errorMessage {
        Text(message)
          .foregroundStyle(.red)
          .font(.footnote)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
    }
    .padding()
  }
}
