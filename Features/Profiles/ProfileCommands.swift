import SwiftUI

/// macOS File menu commands for switching between profiles.
/// Placed before .saveItem to appear near the top of the File menu.
struct ProfileCommands: Commands {
  let profileStore: ProfileStore

  var body: some Commands {
    CommandGroup(before: .saveItem) {
      Menu("Open Profile") {
        ForEach(profileStore.profiles) { profile in
          let isActive = profile.id == profileStore.activeProfileID
          Toggle(
            profile.label,
            isOn: Binding(
              get: { isActive },
              set: { _ in profileStore.setActiveProfile(profile.id) }
            ))
        }

        if profileStore.profiles.isEmpty {
          Text("No Profiles")
        }

        Divider()

        #if os(macOS)
          SettingsLink {
            Text("Manage Profiles…")
          }
        #endif
      }

      Divider()
    }
  }
}
