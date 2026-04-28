import SwiftUI
import UniformTypeIdentifiers

/// Mail-style account management view used in the macOS Settings scene
/// and as a sheet on iOS.
struct SettingsView: View {
  // Environment/State visibility widened from `private` to default (internal)
  // so the `+Actions` / `+macOS` / `+iOS` extension files can read
  // dependencies and mutate state from import/export/delete handlers.
  @Environment(ProfileStore.self) var profileStore
  @Environment(ProfileContainerManager.self) var containerManager
  @Environment(SyncCoordinator.self) var syncCoordinator

  #if os(macOS)
    @Environment(SessionManager.self) var sessionManager
  #else
    let activeSession: ProfileSession?
  #endif

  @State var selectedProfileID: UUID?
  @State var showAddProfile = false
  @State var profileToDelete: Profile?
  @State var showDeleteAlert = false
  @State var showImportPicker = false
  @State var isImporting = false
  @State var importError: String?

  #if os(iOS)
    @State var exportFileURL: URL?
    @State var showExportSheet = false
    @State var isExporting = false
    @State var exportError: String?

    init(activeSession: ProfileSession? = nil) {
      self.activeSession = activeSession
    }
  #endif

  var body: some View {
    #if os(macOS)
      macOSLayout
    #else
      iOSLayout
    #endif
  }

  // MARK: - Per-type detail view

  // Access widened from `private` to default (internal) so the `+iOS` /
  // `+macOS` extensions can render profile detail from their respective
  // layouts.
  @ViewBuilder
  func profileDetailView(for profile: Profile) -> some View {
    #if os(macOS)
      let session = sessionManager.sessions[profile.id]
      let authStore = session?.authStore
    #else
      let isActive = profile.id == profileStore.activeProfileID
      let session = isActive ? activeSession : nil
      let authStore = session?.authStore
    #endif

    switch profile.backendType {
    case .moolah:
      if let session {
        MoolahProfileDetailView(profile: profile, authStore: authStore, session: session)
          .environment(session)
      } else {
        MoolahProfileDetailView(profile: profile, authStore: authStore, session: session)
      }
    case .remote:
      if let session {
        CustomServerProfileDetailView(profile: profile, authStore: authStore, session: session)
          .environment(session)
      } else {
        CustomServerProfileDetailView(profile: profile, authStore: authStore, session: session)
      }
    case .cloudKit:
      CloudKitProfileDetailView(profile: profile)
    }
  }

}

// `MoolahProfileDetailView`, `CustomServerProfileDetailView`,
// `CloudKitProfileDetailView`, and `ProfileAuthStatusView` live in
// `MoolahProfileDetailView.swift`. `ShareSheetView` lives in
// `SettingsView+iOS.swift`. The macOS HSplitView/TabView layout lives in
// `SettingsView+macOS.swift`.
