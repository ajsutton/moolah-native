import SwiftUI

/// Reusable menu content that lists all profiles with a checkmark on the active one.
/// Use inside a `Menu` or as inline content in another menu.
struct ProfileMenuItems: View {
  @Environment(ProfileStore.self) private var profileStore

  var body: some View {
    ForEach(profileStore.profiles) { profile in
      Button {
        profileStore.setActiveProfile(profile.id)
      } label: {
        HStack {
          if profile.id == profileStore.activeProfileID {
            Image(systemName: "checkmark")
              .accessibilityHidden(true)
          }
          Text(profile.label)
        }
      }
    }
  }
}
