import SwiftUI

/// macOS File menu commands for switching between profiles.
/// Profile management is handled by the Settings scene (Cmd+,).
struct ProfileCommands: Commands {
  let profileStore: ProfileStore

  var body: some Commands {
    CommandGroup(before: .newItem) {
      if profileStore.profiles.count > 1 {
        ForEach(profileStore.profiles) { profile in
          Button(profile.label) {
            profileStore.setActiveProfile(profile.id)
          }
          .disabled(profile.id == profileStore.activeProfileID)
        }

        Divider()
      }
    }
  }
}
