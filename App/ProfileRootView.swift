#if os(iOS)
  import SwiftData
  import SwiftUI

  /// Routes between profile states (iOS only):
  /// - No profiles → ProfileSetupView
  /// - Has active session → SessionRootView
  /// - Loading (session not yet created) → ProgressView
  /// On macOS, ProfileWindowView handles this role.
  struct ProfileRootView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(ProfileContainerManager.self) private var containerManager
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Binding var activeSession: ProfileSession?

    var body: some View {
      Group {
        if !profileStore.hasProfiles {
          ProfileSetupView()
        } else if let session = activeSession {
          SessionRootView(session: session)
        } else {
          ProgressView()
        }
      }
      .onChange(of: profileStore.activeProfileID) { _, newID in
        updateSession(for: newID)
      }
      .onChange(of: profileStore.activeProfile?.resolvedServerURL) { _, _ in
        // Recreate session when the active profile's URL changes (e.g. edited in Settings)
        rebuildSessionIfNeeded()
      }
      .onChange(of: profileStore.activeProfile?.label) { _, _ in
        // Update cached profile in session when label changes
        rebuildSessionIfNeeded()
      }
      .onChange(of: profileStore.cloudProfiles) { _, _ in
        // Cloud profiles may arrive late (SwiftData/CloudKit not ready at startup).
        // Retry session creation once they appear.
        if activeSession == nil, let id = profileStore.activeProfileID {
          updateSession(for: id)
        }
      }
      .onChange(of: activeSession?.authStore.state) { _, newState in
        cacheUserNameIfNeeded(newState)
      }
      .onAppear {
        if activeSession == nil, let id = profileStore.activeProfileID {
          updateSession(for: id)
        }
      }
    }

    private func updateSession(for profileID: UUID?) {
      guard let profileID,
        let profile = profileStore.profiles.first(where: { $0.id == profileID })
      else {
        activeSession = nil
        return
      }

      // Only create a new session if profile changed
      if activeSession?.profile.id != profileID {
        activeSession = sessionManager.session(for: profile)
      }
    }

    /// Recreates the session if the active profile's properties changed (e.g. URL edited in Settings).
    private func rebuildSessionIfNeeded() {
      guard let profile = profileStore.activeProfile else { return }
      // Rebuild if the URL changed (needs new backend) or if we have no session yet
      if let session = activeSession,
        session.profile.resolvedServerURL != profile.resolvedServerURL
      {
        sessionManager.rebuildSession(for: profile)
        activeSession = sessionManager.session(for: profile)
      }
    }

    private func cacheUserNameIfNeeded(_ state: AuthStore.State?) {
      guard let state, case .signedIn(let user) = state,
        let session = activeSession,
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
