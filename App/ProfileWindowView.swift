#if os(macOS)
  import OSLog
  import SwiftUI

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileWindowView")

  /// macOS window content for a single profile.
  /// Each window receives a Profile.ID from `WindowGroup(for:)` and resolves it to a session.
  struct ProfileWindowView: View {
    let profileID: Profile.ID?
    @Environment(ProfileStore.self) private var profileStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow

    @Environment(\.dismiss) private var dismiss

    /// Resolve the profile to display: the window's profileID if it matches a known profile,
    /// otherwise the active profile, otherwise the first profile.
    private var resolvedProfile: Profile? {
      if let profileID,
        let profile = profileStore.profiles.first(where: { $0.id == profileID })
      {
        return profile
      }
      if let activeID = profileStore.activeProfileID,
        let profile = profileStore.profiles.first(where: { $0.id == activeID })
      {
        return profile
      }
      return profileStore.profiles.first
    }

    var body: some View {
      Group {
        if let profile = resolvedProfile {
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
        } else if profileStore.isCloudLoadPending {
          ProgressView()
        } else {
          // Profile is genuinely gone — close this window
          let _ = logger.warning(
            "Dismissing window — profile not found. profileID=\(profileID?.uuidString ?? "nil", privacy: .public), profileCount=\(profileStore.profiles.count), profileIDs=\(profileStore.profiles.map(\.id).map(\.uuidString).joined(separator: ","), privacy: .public)"
          )
          Color.clear
            .onAppear {
              dismiss()
            }
        }
      }
    }

    private func cacheUserNameIfNeeded(_ state: AuthStore.State, session: ProfileSession) {
      guard case .signedIn(let user) = state,
        session.profile.backendType != .cloudKit
      else { return }

      let displayName = "\(user.givenName) \(user.familyName)"
      if session.profile.cachedUserName != displayName {
        var updated = session.profile
        updated.cachedUserName = displayName
        profileStore.updateProfile(updated)
      }
    }
  }

#endif
