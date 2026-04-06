import SwiftUI

/// Toolbar button showing the signed-in user's avatar, name, and a sign-out action.
struct UserMenuView: View {
    let user: UserProfile
    @Environment(AuthStore.self) private var authStore

    private let avatarSize: CGFloat = 28

    var body: some View {
        Menu {
            Text("\(user.givenName) \(user.familyName)")
                .font(.headline)

            Divider()

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
            Color.gray.opacity(0.3)
            Image(systemName: "person.fill")
                .font(.system(size: 12))
                .foregroundColor(.white)
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
        .drawingGroup()
    }
}
