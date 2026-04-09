import SwiftUI

/// Mail-style account management view used in the macOS Settings scene
/// and as a sheet on iOS.
struct SettingsView: View {
  @Environment(ProfileStore.self) private var profileStore
  let activeSession: ProfileSession?

  @State private var selectedProfileID: UUID?
  @State private var showAddProfile = false
  @State private var profileToDelete: Profile?
  @State private var showDeleteAlert = false

  init(activeSession: ProfileSession? = nil) {
    self.activeSession = activeSession
  }

  var body: some View {
    #if os(macOS)
      macOSLayout
    #else
      iOSLayout
    #endif
  }

  // MARK: - macOS: HSplitView layout

  #if os(macOS)
    private var macOSLayout: some View {
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
      .frame(minWidth: 500, minHeight: 300)
      .sheet(isPresented: $showAddProfile) {
        ProfileFormView()
          .environment(profileStore)
          .frame(minWidth: 350, minHeight: 250)
      }
      .alert("Remove Profile?", isPresented: $showDeleteAlert) {
        deleteAlertButtons
      } message: {
        deleteAlertMessage
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
        }
      }
      .navigationTitle("Settings")
      .sheet(isPresented: $showAddProfile) {
        ProfileFormView()
          .environment(profileStore)
      }
      .alert("Remove Profile?", isPresented: $showDeleteAlert) {
        deleteAlertButtons
      } message: {
        deleteAlertMessage
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
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Add profile")
          .keyboardShortcut("n", modifiers: [.command, .shift])

          Button {
            if let id = selectedProfileID,
              let profile = profileStore.profiles.first(where: { $0.id == id })
            {
              profileToDelete = profile
              showDeleteAlert = true
            }
          } label: {
            Image(systemName: "minus")
          }
          .buttonStyle(.borderless)
          .disabled(selectedProfileID == nil)
          .accessibilityLabel("Remove selected profile")
          .keyboardShortcut(.delete, modifiers: [])

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
    let isActive = profile.id == profileStore.activeProfileID
    let authStore = isActive ? activeSession?.authStore : nil

    switch profile.backendType {
    case .moolah:
      MoolahProfileDetailView(profile: profile, authStore: authStore)
    case .remote:
      CustomServerProfileDetailView(profile: profile, authStore: authStore)
    }
  }

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
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var deleteAlertButtons: some View {
    Button("Remove", role: .destructive) {
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
      Text(
        "Are you sure you want to remove \"\(profile.label)\"? You will need to sign in again if you re-add it."
      )
    }
  }
}

// MARK: - Moolah Profile Detail

/// Settings detail for a Moolah profile. Shows label and auth status (no URL).
struct MoolahProfileDetailView: View {
  @Environment(ProfileStore.self) private var profileStore
  let profile: Profile
  let authStore: AuthStore?

  @State private var label: String

  init(profile: Profile, authStore: AuthStore?) {
    self.profile = profile
    self.authStore = authStore
    _label = State(initialValue: profile.label)
  }

  var body: some View {
    Form {
      Section("Profile") {
        TextField("Label", text: $label)
          .onChange(of: label) { _, _ in saveLabel() }
      }

      ProfileAuthStatusView(profile: profile, authStore: authStore)
    }
    .formStyle(.grouped)
  }

  private func saveLabel() {
    guard !label.isEmpty, label != profile.label else { return }
    var updated = profile
    updated.label = label
    profileStore.updateProfile(updated)
  }
}

// MARK: - Custom Server Profile Detail

/// Settings detail for a custom server profile. Shows label, URL, and auth status.
struct CustomServerProfileDetailView: View {
  @Environment(ProfileStore.self) private var profileStore
  let profile: Profile
  let authStore: AuthStore?

  @State private var label: String
  @State private var serverURL: String

  init(profile: Profile, authStore: AuthStore?) {
    self.profile = profile
    self.authStore = authStore
    _label = State(initialValue: profile.label)
    _serverURL = State(initialValue: profile.serverURL?.absoluteString ?? "")
  }

  var body: some View {
    Form {
      Section("Server") {
        TextField("Label", text: $label)
          .onChange(of: label) { _, _ in saveLabel() }

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
    }
    .formStyle(.grouped)
  }

  private func saveLabel() {
    guard !label.isEmpty, label != profile.label else { return }
    var updated = profile
    updated.label = label
    profileStore.updateProfile(updated)
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
    case .signedIn(let user):
      HStack {
        Image(systemName: "person.crop.circle.fill")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("\(user.givenName) \(user.familyName)")
        Spacer()
        Button("Sign Out", role: .destructive) {
          Task { await authStore.signOut() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Signed in as \(user.givenName) \(user.familyName)")
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
      if let name = profile.cachedUserName {
        Image(systemName: "person.crop.circle.fill")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(name)
      } else {
        Text("Not signed in")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("Switch to this profile to sign in")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
