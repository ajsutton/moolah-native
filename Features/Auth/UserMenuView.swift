import SwiftUI

/// Toolbar button showing the signed-in user's avatar, name, and a sign-out action.
/// Also shows profile switching when multiple profiles exist.
struct UserMenuView: View {
  let user: UserProfile
  @Environment(AuthStore.self) private var authStore
  @Environment(ProfileStore.self) private var profileStore
  @State private var showAddProfile = false

  private let avatarSize: CGFloat = 28

  var body: some View {
    Menu {
      Text("\(user.givenName) \(user.familyName)")
        .font(.headline)

      Divider()

      profileSection

      Button(String(localized: "Sign Out"), role: .destructive) {
        Task { await authStore.signOut() }
      }
    } label: {
      HStack(spacing: 6) {
        avatarView
        Text(user.givenName)
          .font(.subheadline)
      }
      .frame(height: avatarSize)
    }
    .accessibilityLabel(
      String(localized: "User menu for \(user.givenName) \(user.familyName)")
    )
    .sheet(isPresented: $showAddProfile) {
      AddProfileView()
        .environment(profileStore)
    }
  }

  // MARK: - Profile Section

  @ViewBuilder
  private var profileSection: some View {
    ForEach(profileStore.profiles) { profile in
      Button {
        profileStore.setActiveProfile(profile.id)
      } label: {
        HStack {
          if profile.id == profileStore.activeProfileID {
            Image(systemName: "checkmark")
          }
          Text(profile.label)
        }
      }
    }

    Button(String(localized: "Add Profile...")) {
      showAddProfile = true
    }

    Divider()
  }

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
      #if os(macOS)
        Color(nsColor: .quaternaryLabelColor)
      #else
        Color(uiColor: .quaternaryLabel)
      #endif
      Image(systemName: "person.fill")
        .font(.system(size: 12))
        .foregroundStyle(.white)
    }
    .frame(width: avatarSize, height: avatarSize)
    .clipShape(Circle())
    .drawingGroup()
  }
}
