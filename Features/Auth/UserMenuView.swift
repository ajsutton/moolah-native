import SwiftUI

/// Toolbar button showing the signed-in user's avatar, name, and a sign-out action.
struct UserMenuView: View {
    let user: UserProfile
    @Environment(AuthStore.self) private var authStore

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
        }
        .accessibilityLabel(String(localized: "User menu for \(user.givenName) \(user.familyName)"))
    }

    @ViewBuilder
    private var avatarView: some View {
        if let url = user.pictureURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.gray.opacity(0.3))
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .imageScale(.large)
        }
    }
}
