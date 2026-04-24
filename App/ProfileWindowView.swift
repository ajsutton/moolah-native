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
    @Environment(\.pendingNavigation) private var pendingNavigationBinding

    @Environment(\.dismiss) private var dismiss

    /// Resolve the profile to display: the window's profileID if it matches a
    /// known profile, otherwise the active profile. Falls back to the single
    /// profile only when exactly one exists — with 2+ profiles and nothing
    /// selected, `WelcomeView` shows its picker (state 5) instead of
    /// silently opening one of them.
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
      return profileStore.profiles.count == 1 ? profileStore.profiles.first : nil
    }

    var body: some View {
      Group {
        if let profile = resolvedProfile {
          let session = sessionManager.session(for: profile)
          SessionRootView(session: session)
            .environment(profileStore)
            .onChange(of: profile.resolvedServerURL) { _, _ in
              sessionManager.rebuildSession(for: profile)
            }
        } else if profileID != nil {
          // This window was opened for a specific profile that no longer
          // exists. Close it — the user will land on whichever window
          // SwiftUI brings forward next.
          Color.clear
            .onAppear {
              logger.warning(
                "Dismissing window — profile not found. profileID=\(profileID?.uuidString ?? "nil", privacy: .public), profileCount=\(profileStore.profiles.count), profileIDs=\(profileStore.profiles.map(\.id).map(\.uuidString).joined(separator: ","), privacy: .public)"
              )
              dismiss()
            }
        } else {
          // No specific profile requested AND no active profile. Covers
          // both the empty first-run case (`!hasProfiles` → hero state 1)
          // and the multi-profile-no-selection case (2+ profiles, none
          // picked → picker state 5). `WelcomeView`'s state machine
          // picks the right branch.
          WelcomeView()
            .onChange(of: profileStore.profiles) { _, newProfiles in
              if newProfiles.count == 1, let first = newProfiles.first {
                openWindow(value: first.id)
              }
            }
        }
      }
      .background(tagHostingWindow)
      .task {
        // Register in-process entry points for AppleScript/App Intents so
        // `NavigateCommand` / `OpenAccountIntent` don't need to round-trip
        // through `NSWorkspace.shared.open(moolah://…)` — SwiftUI's
        // auto-spawn of a stray window on URL events (issue #378) — and
        // since the URL scheme itself has been removed (issue #386),
        // in-process is the only remaining path.
        let openAction = openWindow
        let pendingBinding = pendingNavigationBinding
        NavigationBridge.openProfile = { id in openAction(value: id) }
        NavigationBridge.setPendingNavigation = { nav in
          pendingBinding?.wrappedValue = nav
        }
      }
    }

    /// Stamps the hosting `NSWindow.identifier` with a per-profile identifier
    /// so `ProfileWindowLocator` can find and focus the window when AppleScript
    /// or an App Intent opens a profile that is already on screen.
    @ViewBuilder private var tagHostingWindow: some View {
      if let profile = resolvedProfile {
        WindowAccessor { window in
          window.identifier = ProfileWindowLocator.identifier(for: profile.id)
        }
      }
    }

  }

#endif
