import SwiftUI
import UniformTypeIdentifiers

/// Mail-style account management view used in the macOS Settings scene
/// and as a sheet on iOS.
struct SettingsView: View {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(ProfileContainerManager.self) private var containerManager
  @Environment(SyncCoordinator.self) private var syncCoordinator

  #if os(macOS)
    @Environment(SessionManager.self) private var sessionManager
  #else
    let activeSession: ProfileSession?
  #endif

  @State private var selectedProfileID: UUID?
  @State private var showAddProfile = false
  @State private var profileToDelete: Profile?
  @State private var showDeleteAlert = false
  @State private var showImportPicker = false
  @State private var isImporting = false
  @State private var importError: String?

  #if os(iOS)
    @State private var exportFileURL: URL?
    @State private var showExportSheet = false
    @State private var isExporting = false
    @State private var exportError: String?

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
      if let session = sessionManager.sessions.values.first {
        return session.cryptoTokenStore
      }
      let fallbackService = CryptoPriceService(
        clients: [CryptoCompareClient(), BinanceClient()],
        tokenRepository: ICloudTokenRepository(),
        resolutionClient: CompositeTokenResolutionClient()
      )
      return CryptoTokenStore(cryptoPriceService: fallbackService)
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
          ImportSettingsView()
        }
        Tab("Rules", systemImage: "list.bullet.rectangle") {
          ImportRulesSettingsView()
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
  #endif

  // MARK: - iOS: NavigationStack layout

  #if os(iOS)
    private var cryptoTokenStoreForSettings: CryptoTokenStore {
      if let session = activeSession {
        return session.cryptoTokenStore
      }
      let fallbackService = CryptoPriceService(
        clients: [CryptoCompareClient(), BinanceClient()],
        tokenRepository: ICloudTokenRepository(),
        resolutionClient: CompositeTokenResolutionClient()
      )
      return CryptoTokenStore(cryptoPriceService: fallbackService)
    }

    private var iOSLayout: some View {
      List {
        Section("Profiles") {
          ForEach(profileStore.profiles) { profile in
            NavigationLink {
              profileDetailView(for: profile)
                .navigationTitle(profile.label)
            } label: {
              profileRow(profile)
            }
            .swipeActions(edge: .leading) {
              if profile.backendType == .cloudKit,
                profile.id == profileStore.activeProfileID
              {
                Button {
                  Task { await handleExport(profile: profile) }
                } label: {
                  Label("Export", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
              }
            }
          }
          .onDelete { indexSet in
            if let index = indexSet.first {
              profileToDelete = profileStore.profiles[index]
              showDeleteAlert = true
            }
          }
        }

        Section {
          Button {
            showAddProfile = true
          } label: {
            Label("Add Profile", systemImage: "plus")
          }

          Button {
            showImportPicker = true
          } label: {
            Label("Import Profile", systemImage: "square.and.arrow.down")
          }
        }

        Section {
          NavigationLink {
            CryptoSettingsView(store: cryptoTokenStoreForSettings)
          } label: {
            Label("Crypto Tokens", systemImage: "bitcoinsign.circle")
          }
        }

        Section("Import") {
          NavigationLink {
            ImportSettingsView()
          } label: {
            Label("CSV Import", systemImage: "tray.and.arrow.down")
          }
          NavigationLink {
            ImportRulesSettingsView()
          } label: {
            Label("Import Rules", systemImage: "list.bullet.rectangle")
          }
        }
      }
      .navigationTitle("Settings")
      .overlay {
        if isImporting || isExporting {
          ProgressView(isImporting ? "Importing\u{2026}" : "Exporting\u{2026}")
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .sheet(isPresented: $showAddProfile) {
        ProfileFormView()
          .environment(profileStore)
      }
      .sheet(isPresented: $showExportSheet) {
        if let exportFileURL {
          ShareSheetView(url: exportFileURL)
        }
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
      .alert(
        "Export Failed",
        isPresented: .init(
          get: { exportError != nil },
          set: { if !$0 { exportError = nil } }
        )
      ) {
        Button("OK") { exportError = nil }
      } message: {
        if let exportError {
          Text(exportError)
        }
      }
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
    @ViewBuilder
    private var detailPane: some View {
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

  @ViewBuilder
  private func profileDetailView(for profile: Profile) -> some View {
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

  // MARK: - Import

  private func handleImport(result: Result<URL, Error>) async {
    guard case .success(let url) = result else {
      if case .failure(let error) = result {
        importError = error.localizedDescription
      }
      return
    }
    guard url.startAccessingSecurityScopedResource() else {
      importError = "Could not access the selected file."
      return
    }
    defer { url.stopAccessingSecurityScopedResource() }

    isImporting = true
    defer { isImporting = false }

    do {
      let jsonData = try Data(contentsOf: url)
      let exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)

      let newProfile = Profile(
        label: exported.profileLabel,
        backendType: .cloudKit,
        currencyCode: exported.currencyCode,
        financialYearStartMonth: exported.financialYearStartMonth
      )
      profileStore.addProfile(newProfile)

      do {
        let container = try containerManager.container(for: newProfile.id)
        let coordinator = MigrationCoordinator()
        _ = try await coordinator.importFromFile(
          url: url,
          modelContainer: container,
          profileId: newProfile.id,
          syncCoordinator: syncCoordinator
        )
        profileStore.setActiveProfile(newProfile.id)
      } catch {
        containerManager.deleteStore(for: newProfile.id)
        profileStore.removeProfile(newProfile.id)
        throw error
      }
    } catch {
      importError = error.localizedDescription
    }
  }

  // MARK: - Export (iOS)

  #if os(iOS)
    private func handleExport(profile: Profile) async {
      guard let backend = activeSession?.backend else {
        exportError = "Switch to this profile before exporting."
        return
      }

      isExporting = true
      defer { isExporting = false }

      do {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "\(profile.label).json"
        let tempURL = tempDir.appendingPathComponent(filename)

        let coordinator = MigrationCoordinator()
        try await coordinator.exportToFile(
          url: tempURL,
          backend: backend,
          profile: profile
        )

        exportFileURL = tempURL
        showExportSheet = true
      } catch {
        exportError = error.localizedDescription
      }
    }
  #endif

  // MARK: - Shared Components

  private func profileRow(_ profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(profile.label)
        .font(.headline)
      switch profile.backendType {
      case .moolah:
        Text("moolah.rocks")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .remote:
        Text(profile.resolvedServerURL.host() ?? profile.resolvedServerURL.absoluteString)
          .font(.caption)
          .foregroundStyle(.secondary)
      case .cloudKit:
        Text("iCloud")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var deleteAlertTitle: String {
    if let profile = profileToDelete, profile.backendType == .cloudKit {
      return "Delete \(profile.label)?"
    }
    return "Remove Profile?"
  }

  @ViewBuilder
  private var deleteAlertButtons: some View {
    Button(profileToDelete?.backendType == .cloudKit ? "Delete" : "Remove", role: .destructive) {
      if let profile = profileToDelete {
        profileStore.removeProfile(profile.id)
        if selectedProfileID == profile.id {
          selectedProfileID = profileStore.profiles.first?.id
        }
        profileToDelete = nil
      }
    }
    Button("Cancel", role: .cancel) {
      profileToDelete = nil
    }
  }

  @ViewBuilder
  private var deleteAlertMessage: some View {
    if let profile = profileToDelete {
      if profile.backendType == .cloudKit {
        Text(
          "This will permanently delete all accounts, transactions, and other data in this profile across all your devices. This cannot be undone."
        )
      } else {
        Text(
          "Are you sure you want to remove \"\(profile.label)\"? You will need to sign in again if you re-add it."
        )
      }
    }
  }
}

// MARK: - Moolah Profile Detail

/// Settings detail for a Moolah profile. Shows label and auth status (no URL).
struct MoolahProfileDetailView: View {
  @Environment(ProfileStore.self) private var profileStore
  let profile: Profile
  let authStore: AuthStore?
  let session: ProfileSession?

  @State private var label: String
  @State private var currencyCode: String
  @State private var financialYearStartMonth: Int
  @State private var showMigration = false

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  init(profile: Profile, authStore: AuthStore?, session: ProfileSession?) {
    self.profile = profile
    self.authStore = authStore
    self.session = session
    _label = State(initialValue: profile.label)
    _currencyCode = State(initialValue: profile.currencyCode)
    _financialYearStartMonth = State(initialValue: profile.financialYearStartMonth)
  }

  var body: some View {
    Form {
      Section("Profile") {
        TextField("Label", text: $label)
          .onChange(of: label) { _, _ in saveChanges() }
      }

      Section("Settings") {
        CurrencyPicker(selection: $currencyCode)
          .onChange(of: currencyCode) { _, _ in saveChanges() }

        Picker("Financial Year Starts", selection: $financialYearStartMonth) {
          ForEach(1...12, id: \.self) { month in
            if month <= Self.monthNames.count {
              Text(Self.monthNames[month - 1])
                .tag(month)
            }
          }
        }
        .onChange(of: financialYearStartMonth) { _, _ in saveChanges() }
      }

      ProfileAuthStatusView(profile: profile, authStore: authStore)

      if let session {
        MigrateToICloudSection(
          profile: profile,
          session: session,
          showMigration: $showMigration
        )
      }
    }
    .formStyle(.grouped)
  }

  private func saveChanges() {
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
    guard !trimmedLabel.isEmpty else { return }

    var updated = profile
    var changed = false

    if trimmedLabel != profile.label {
      updated.label = trimmedLabel
      changed = true
    }
    if currencyCode != profile.currencyCode {
      updated.currencyCode = currencyCode
      changed = true
    }
    if financialYearStartMonth != profile.financialYearStartMonth {
      updated.financialYearStartMonth = financialYearStartMonth
      changed = true
    }

    if changed {
      profileStore.updateProfile(updated)
    }
  }
}

// MARK: - Custom Server Profile Detail

/// Settings detail for a custom server profile. Shows label, URL, and auth status.
struct CustomServerProfileDetailView: View {
  @Environment(ProfileStore.self) private var profileStore
  let profile: Profile
  let authStore: AuthStore?
  let session: ProfileSession?

  @State private var label: String
  @State private var serverURL: String
  @State private var currencyCode: String
  @State private var financialYearStartMonth: Int
  @State private var showMigration = false

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  init(profile: Profile, authStore: AuthStore?, session: ProfileSession?) {
    self.profile = profile
    self.authStore = authStore
    self.session = session
    _label = State(initialValue: profile.label)
    _serverURL = State(initialValue: profile.serverURL?.absoluteString ?? "")
    _currencyCode = State(initialValue: profile.currencyCode)
    _financialYearStartMonth = State(initialValue: profile.financialYearStartMonth)
  }

  var body: some View {
    Form {
      Section("Server") {
        TextField("Label", text: $label)
          .onChange(of: label) { _, _ in saveChanges() }

        TextField("Server URL", text: $serverURL)
          .autocorrectionDisabled()
          #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
          #endif
          .onSubmit { Task { await saveURL() } }
          .onChange(of: serverURL) {
            profileStore.clearValidationError()
          }
      }

      Section("Settings") {
        CurrencyPicker(selection: $currencyCode)
          .onChange(of: currencyCode) { _, _ in saveChanges() }

        Picker("Financial Year Starts", selection: $financialYearStartMonth) {
          ForEach(1...12, id: \.self) { month in
            if month <= Self.monthNames.count {
              Text(Self.monthNames[month - 1])
                .tag(month)
            }
          }
        }
        .onChange(of: financialYearStartMonth) { _, _ in saveChanges() }
      }

      if profileStore.isValidating {
        Section {
          HStack {
            Spacer()
            ProgressView("Validating server...")
            Spacer()
          }
        }
      } else if let error = profileStore.validationError {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(error)")
        }
      }

      ProfileAuthStatusView(profile: profile, authStore: authStore)

      if let session {
        MigrateToICloudSection(
          profile: profile,
          session: session,
          showMigration: $showMigration
        )
      }
    }
    .formStyle(.grouped)
  }

  private func saveChanges() {
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
    guard !trimmedLabel.isEmpty else { return }

    var updated = profile
    var changed = false

    if trimmedLabel != profile.label {
      updated.label = trimmedLabel
      changed = true
    }
    if currencyCode != profile.currencyCode {
      updated.currencyCode = currencyCode
      changed = true
    }
    if financialYearStartMonth != profile.financialYearStartMonth {
      updated.financialYearStartMonth = financialYearStartMonth
      changed = true
    }

    if changed {
      profileStore.updateProfile(updated)
    }
  }

  private func saveURL() async {
    let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
    guard let url = URL(string: urlString), url != profile.serverURL else { return }

    var updated = profile
    updated.serverURL = url
    updated.label = label.isEmpty ? url.host() ?? "Custom Server" : label
    _ = await profileStore.validateAndUpdateProfile(updated)
  }
}

// MARK: - Auth Status (shared)

/// Shows authentication status and sign-in/sign-out actions.
/// Only the active profile gets live auth state and action buttons.
struct ProfileAuthStatusView: View {
  let profile: Profile
  let authStore: AuthStore?

  var body: some View {
    Section("Account") {
      if let authStore {
        liveAuthStatus(authStore)
      } else {
        offlineAuthStatus
      }
    }
  }

  @ViewBuilder
  private func liveAuthStatus(_ authStore: AuthStore) -> some View {
    switch authStore.state {
    case .loading:
      HStack {
        Text("Checking...")
        Spacer()
        ProgressView()
          .controlSize(.small)
      }
      .accessibilityElement(children: .combine)
    case .signedIn:
      HStack {
        Image(systemName: "person.crop.circle.fill")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("Signed in")
        Spacer()
        if authStore.requiresSignIn {
          Button("Sign Out", role: .destructive) {
            Task { await authStore.signOut() }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Signed in")
    case .signedOut:
      HStack {
        Text("Not signed in")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Sign In") {
          Task { await authStore.signIn() }
        }
        #if os(macOS)
          .buttonStyle(.bordered)
        #else
          .buttonStyle(.borderedProminent)
        #endif
        .controlSize(.small)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var offlineAuthStatus: some View {
    HStack {
      Text("Not signed in")
        .foregroundStyle(.secondary)
      Spacer()
      #if os(macOS)
        Text("Open this profile to sign in")
          .font(.caption)
          .foregroundStyle(.secondary)
      #else
        Text("Switch to this profile to sign in")
          .font(.caption)
          .foregroundStyle(.secondary)
      #endif
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - iCloud Profile Detail

/// Settings detail for an iCloud profile. Shows label, currency, and financial year start.
struct CloudKitProfileDetailView: View {
  @Environment(ProfileStore.self) private var profileStore
  let profile: Profile

  @State private var label: String
  @State private var currencyCode: String
  @State private var financialYearStartMonth: Int

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  init(profile: Profile) {
    self.profile = profile
    _label = State(initialValue: profile.label)
    _currencyCode = State(initialValue: profile.currencyCode)
    _financialYearStartMonth = State(initialValue: profile.financialYearStartMonth)
  }

  var body: some View {
    Form {
      Section("Profile") {
        TextField("Name", text: $label)
          .onChange(of: label) { _, _ in saveChanges() }

        HStack {
          Text("Storage")
          Spacer()
          Label("iCloud", systemImage: "icloud")
            .foregroundStyle(.secondary)
        }
      }

      Section("Settings") {
        CurrencyPicker(selection: $currencyCode)
          .onChange(of: currencyCode) { _, _ in saveChanges() }

        Picker("Financial Year Starts", selection: $financialYearStartMonth) {
          ForEach(1...12, id: \.self) { month in
            if month <= Self.monthNames.count {
              Text(Self.monthNames[month - 1])
                .tag(month)
            }
          }
        }
        .onChange(of: financialYearStartMonth) { _, _ in saveChanges() }
      }
    }
    .formStyle(.grouped)
  }

  private func saveChanges() {
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
    guard !trimmedLabel.isEmpty else { return }

    var updated = profile
    var changed = false

    if trimmedLabel != profile.label {
      updated.label = trimmedLabel
      changed = true
    }
    if currencyCode != profile.currencyCode {
      updated.currencyCode = currencyCode
      changed = true
    }
    if financialYearStartMonth != profile.financialYearStartMonth {
      updated.financialYearStartMonth = financialYearStartMonth
      changed = true
    }

    if changed {
      profileStore.updateProfile(updated)
    }
  }
}

// MARK: - iOS Share Sheet

#if os(iOS)
  /// Wraps UIActivityViewController for presenting a share sheet with a file URL.
  struct ShareSheetView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(
      _ uiViewController: UIActivityViewController, context: Context
    ) {}
  }
#endif
