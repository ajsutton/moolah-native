import SwiftUI

/// On macOS: static label showing profile name (sign out is in File menu).
/// On iOS: dropdown menu with profile switcher, manage profiles, and sign out.
struct UserMenuView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(ProfileStore.self) private var profileStore
  @Environment(ProfileSession.self) private var session
  @State private var showManageProfiles = false

  private let avatarSize: CGFloat = 28

  var body: some View {
    #if os(macOS)
      macOSUserLabel
    #else
      iOSUserMenu
    #endif
  }

  // MARK: - macOS: Static label (sign out is in File menu)

  #if os(macOS)
    private var macOSUserLabel: some View {
      Text(session.profile.label)
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: avatarSize)
        .accessibilityLabel(session.profile.label)
    }
  #endif

  // MARK: - iOS: Full menu with profile switcher and sign out

  #if os(iOS)
    private var iOSUserMenu: some View {
      Menu {
        Text(session.profile.label)
          .font(.headline)

        Divider()

        profileSection

        if authStore.requiresSignIn {
          Button(String(localized: "Sign Out"), role: .destructive) {
            Task { await authStore.signOut() }
          }
        }
      } label: {
        HStack(spacing: 6) {
          avatarView
          Text(session.profile.label)
            .font(.subheadline)
        }
        .frame(height: avatarSize)
      }
      .accessibilityLabel(
        String(localized: "User menu for \(session.profile.label)")
      )
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
    }
  #endif

  // MARK: - Profile Section (iOS only)

  #if os(iOS)
    @ViewBuilder private var profileSection: some View {
      ProfileMenuItems()

      Button(String(localized: "Manage Profiles...")) {
        showManageProfiles = true
      }

      Divider()
    }
  #endif

  // MARK: - Avatar

  private var avatarView: some View {
    Group {
      placeholder
    }
    .frame(width: avatarSize, height: avatarSize)
  }

  // MARK: - Placeholder

  private var placeholder: some View {
    ZStack {
      Color.secondary.opacity(0.15)
      Image(systemName: "person.fill")
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .accessibilityHidden(true)
    }
    .frame(width: avatarSize, height: avatarSize)
    .clipShape(Circle())
    .drawingGroup()
  }
}
