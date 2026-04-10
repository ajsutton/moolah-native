#if os(macOS)
  import SwiftUI

  /// macOS File menu commands for opening profile windows and signing out.
  struct ProfileCommands: Commands {
    let profileStore: ProfileStore
    let sessionManager: SessionManager

    @FocusedValue(\.authStore) private var authStore

    var body: some Commands {
      CommandGroup(before: .saveItem) {
        OpenProfileMenu(profileStore: profileStore)

        Divider()
      }

      CommandGroup(after: .singleWindowList) {
        Button("Sign Out") {
          if let authStore {
            Task { await authStore.signOut() }
          }
        }
        .disabled(authStore == nil)
        .keyboardShortcut("o", modifiers: [.command, .shift])
      }
    }
  }

  /// Wrapper view to access `@Environment(\.openWindow)` inside commands.
  private struct OpenProfileMenu: View {
    let profileStore: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
      Menu("Open Profile") {
        ForEach(profileStore.profiles) { profile in
          Button(profile.label) {
            openWindow(value: profile.id)
          }
        }

        if profileStore.profiles.isEmpty {
          Text("No Profiles")
        }

        Divider()

        SettingsLink {
          Text("Manage Profiles…")
        }
      }
    }
  }
#endif
