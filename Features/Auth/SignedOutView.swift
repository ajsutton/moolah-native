import SwiftUI

/// Shown when a Moolah-server profile has lost its authentication
/// (the session is signed out but the profile still exists).
/// The "Sign in with Google" button is hidden when requiresExplicitSignIn is
/// false (e.g. a future CloudKit backend that authenticates implicitly via
/// Apple ID).
///
/// Distinct from `Features/Profiles/Views/WelcomeView` — that's the
/// first-run profile-setup flow.
struct SignedOutView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(ProfileStore.self) private var profileStore

  #if os(iOS)
    @Environment(ProfileSession.self) private var session
    @State private var showManageProfiles = false
  #endif

  var body: some View {
    VStack(spacing: 32) {
      header

      #if os(iOS)
        if profileStore.profiles.count > 1 {
          profilePicker
        }
      #endif

      if authStore.requiresSignIn {
        signInButton
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
    #if os(iOS)
      .sheet(isPresented: $showManageProfiles) {
        NavigationStack {
          SettingsView(activeSession: session)
          .environment(profileStore)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") { showManageProfiles = false }
            }
          }
        }
      }
    #endif
  }

  private var header: some View {
    VStack(spacing: 8) {
      Text("Moolah")
        .font(.largeTitle.bold())
      Text(String(localized: "Personal finance, your way."))
        .foregroundStyle(.secondary)
    }
  }

  private var signInButton: some View {
    Button {
      Task { await authStore.signIn() }
    } label: {
      Label(
        String(localized: "Sign in with Google"),
        systemImage: "person.crop.circle.badge.checkmark"
      )
      .frame(maxWidth: 280)
    }
    #if os(macOS)
      .buttonStyle(.bordered)
    #else
      .buttonStyle(.borderedProminent)
    #endif
    .controlSize(.large)
  }

  #if os(iOS)
    private var profilePicker: some View {
      Menu {
        ProfileMenuItems()

        Divider()

        Button(String(localized: "Manage Profiles...")) {
          showManageProfiles = true
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "person.crop.circle")
            .foregroundStyle(.secondary)
          Text(profileStore.activeProfile?.label ?? "")
            .font(.subheadline)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: .capsule)
      }
      .accessibilityLabel("Switch profile")
    }
  #endif
}
