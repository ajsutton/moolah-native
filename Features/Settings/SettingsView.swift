import SwiftUI
import UniformTypeIdentifiers

/// Mail-style account management view used in the macOS Settings scene
/// and as a sheet on iOS.
struct SettingsView: View {
  // Environment/State visibility widened from `private` to default (internal)
  // so the `+Actions` extension file can read dependencies and mutate state
  // from import/export/delete handlers.
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

  // MARK: - macOS: HSplitView layout

  #if os(macOS)
    private var cryptoTokenStoreForSettings: CryptoTokenStore {
      if let session = sessionForSettings {
        return session.cryptoTokenStore
      }
      let fallbackService = CryptoPriceService(
        clients: [CryptoCompareClient(), BinanceClient()],
        tokenRepository: ICloudTokenRepository(),
        resolutionClient: CompositeTokenResolutionClient()
      )
      return CryptoTokenStore(cryptoPriceService: fallbackService)
    }

    /// The Settings scene lives outside `SessionRootView`, so the session
    /// stores aren't in its environment. Resolve one here for the tabs
    /// that depend on per-profile state. Prefer the active profile; fall
    /// back to any open session so Settings still renders after a profile
    /// switch.
    private var sessionForSettings: ProfileSession? {
      if let id = profileStore.activeProfileID, let session = sessionManager.sessions[id] {
        return session
      }
      return sessionManager.sessions.values.first
    }

    private var macOSLayout: some View {
      TabView {
        Tab("Profiles", systemImage: "person.2") {
          profilesContent
        }
        Tab("Crypto", systemImage: "bitcoinsign.circle") {
          CryptoSettingsView(store: cryptoTokenStoreForSettings)
        }
        // macOS Settings tabs host the Form / List directly — the window
        // already supplies chrome and a title, so wrapping in a second
        // `NavigationStack` would produce a duplicate navigation bar.
        Tab("Import", systemImage: "tray.and.arrow.down") {
          importTabContent
        }
        Tab("Rules", systemImage: "list.bullet.rectangle") {
          rulesTabContent
        }
      }
      .frame(minWidth: 600, minHeight: 400)
      .sheet(isPresented: $showAddProfile) {
        ProfileFormView()
          .environment(profileStore)
          .frame(minWidth: 400, minHeight: 300)
      }
      .alert(deleteAlertTitle, isPresented: $showDeleteAlert) {
        deleteAlertButtons
      } message: {
        deleteAlertMessage
      }
      .fileImporter(
        isPresented: $showImportPicker,
        allowedContentTypes: [.json]
      ) { result in
        Task { await handleImport(result: result) }
      }
      .alert(
        "Import Failed",
        isPresented: .init(
          get: { importError != nil },
          set: { if !$0 { importError = nil } }
        )
      ) {
        Button("OK") { importError = nil }
      } message: {
        if let importError {
          Text(importError)
        }
      }
    }

    private var profilesContent: some View {
      Group {
        if profileStore.profiles.isEmpty {
          emptyState
        } else {
          HSplitView {
            profileList
              .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            detailPane
              .frame(minWidth: 300, idealWidth: 400)
          }
          .onAppear {
            if selectedProfileID == nil {
              selectedProfileID =
                profileStore.activeProfileID ?? profileStore.profiles.first?.id
            }
          }
        }
      }
    }

    private var emptyState: some View {
      ContentUnavailableView {
        Label("No Profiles", systemImage: "person.crop.circle.badge.plus")
      } description: {
        Text("Add a profile to connect to a Moolah server.")
      } actions: {
        Button("Add Profile") {
          showAddProfile = true
        }
        .buttonStyle(.bordered)
      }
    }

    @ViewBuilder private var importTabContent: some View {
      if let session = sessionForSettings {
        ImportSettingsView()
          .environment(session)
      } else {
        noActiveProfilePlaceholder
      }
    }

    @ViewBuilder private var rulesTabContent: some View {
      if let session = sessionForSettings {
        ImportRulesSettingsView()
          .environment(session)
          .environment(session.importRuleStore)
          .environment(session.categoryStore)
      } else {
        noActiveProfilePlaceholder
      }
    }

    private var noActiveProfilePlaceholder: some View {
      ContentUnavailableView(
        "No Profile",
        systemImage: "person.crop.circle",
        description: Text("Add a profile to configure this tab.")
      )
    }
  #endif

  // MARK: - macOS Profile List (sidebar)

  #if os(macOS)
    private var profileList: some View {
      VStack(spacing: 0) {
        List(selection: $selectedProfileID) {
          Section("Profiles") {
            ForEach(profileStore.profiles) { profile in
              profileRow(profile)
                .tag(profile.id)
            }
          }
        }
        .listStyle(.sidebar)

        Divider()

        HStack(spacing: 8) {
          Button {
            showAddProfile = true
          } label: {
            Image(systemName: "plus")
              .frame(minWidth: 24, minHeight: 24)
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Add profile")

          Button {
            if let id = selectedProfileID,
              let profile = profileStore.profiles.first(where: { $0.id == id })
            {
              profileToDelete = profile
              showDeleteAlert = true
            }
          } label: {
            Image(systemName: "minus")
              .frame(minWidth: 24, minHeight: 24)
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .disabled(selectedProfileID == nil)
          .accessibilityLabel("Remove selected profile")

          Button {
            showImportPicker = true
          } label: {
            Image(systemName: "square.and.arrow.down")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Import profile")

          Spacer()
        }
        .padding(8)
      }
    }
  #endif

  // MARK: - macOS Detail Pane

  #if os(macOS)
    @ViewBuilder private var detailPane: some View {
      if let selectedID = selectedProfileID,
        let profile = profileStore.profiles.first(where: { $0.id == selectedID })
      {
        profileDetailView(for: profile)
          .id(selectedID)
      } else {
        ContentUnavailableView(
          "No Profile Selected",
          systemImage: "person.crop.circle",
          description: Text("Select a profile to view its settings.")
        )
      }
    }
  #endif

  // MARK: - Per-type detail view

  // Access widened from `private` to default (internal) so the `+iOS`
  // extension can render profile detail from the iOS list.
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
      MoolahProfileDetailView(profile: profile, authStore: authStore, session: session)
    case .remote:
      CustomServerProfileDetailView(profile: profile, authStore: authStore, session: session)
    case .cloudKit:
      CloudKitProfileDetailView(profile: profile)
    }
  }

}

// `MoolahProfileDetailView`, `CustomServerProfileDetailView`,
// `CloudKitProfileDetailView`, `ProfileAuthStatusView`, and the iOS
// `ShareSheetView` live in `MoolahProfileDetailView.swift`.
