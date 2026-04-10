#if os(macOS)
  import SwiftUI

  /// macOS window content for a single profile.
  /// Each window receives a Profile.ID from `WindowGroup(for:)` and resolves it to a session.
  struct ProfileWindowView: View {
    let profileID: Profile.ID?
    @Environment(ProfileStore.self) private var profileStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
      Group {
        if let profileID,
          let profile = profileStore.profiles.first(where: { $0.id == profileID })
        {
          let session = sessionManager.session(for: profile)
          SessionRootView(session: session)
            .environment(profileStore)
            .onChange(of: session.authStore.state) { _, newState in
              cacheUserNameIfNeeded(newState, session: session)
            }
            .onChange(of: profile.resolvedServerURL) { _, _ in
              sessionManager.rebuildSession(for: profile)
            }
        } else if !profileStore.hasProfiles {
          ProfileSetupView()
            .onChange(of: profileStore.profiles) { _, newProfiles in
              if let first = newProfiles.first {
                openWindow(value: first.id)
              }
            }
        } else {
          ContentUnavailableView(
            "Profile Not Found",
            systemImage: "person.crop.circle.badge.xmark",
            description: Text("This profile has been removed.")
          )
        }
      }
    }

    private func cacheUserNameIfNeeded(_ state: AuthStore.State, session: ProfileSession) {
      guard case .signedIn(let user) = state else { return }

      let displayName = "\(user.givenName) \(user.familyName)"
      if session.profile.cachedUserName != displayName {
        var updated = session.profile
        updated.cachedUserName = displayName
        profileStore.updateProfile(updated)
      }
    }
  }

#endif
