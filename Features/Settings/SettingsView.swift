import SwiftUI

/// Mail-style account management view used in the macOS Settings scene
/// and as a sheet on iOS.
struct SettingsView: View {
  @Environment(ProfileStore.self) private var profileStore
  @State private var selectedProfileID: UUID?
  @State private var showAddProfile = false
  @State private var profileToDelete: Profile?
  @State private var showDeleteAlert = false

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
              iOSProfileDetail(profile: profile)
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

    private func iOSProfileDetail(profile: Profile) -> some View {
      ProfileDetailView(profile: profile)
        .navigationTitle(profile.label)
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
        ProfileDetailView(profile: profile)
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

  // MARK: - Shared Components

  private func profileRow(_ profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(profile.label)
        .font(.headline)
      Text(profile.serverURL.host() ?? profile.serverURL.absoluteString)
        .font(.caption)
        .foregroundStyle(.secondary)
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

/// Inline detail editing for a selected profile.
/// Changes auto-apply like Apple Mail's account settings.
struct ProfileDetailView: View {
  @Environment(ProfileStore.self) private var profileStore

  let profile: Profile

  @State private var label: String
  @State private var serverURL: String

  init(profile: Profile) {
    self.profile = profile
    _label = State(initialValue: profile.label)
    _serverURL = State(initialValue: profile.serverURL.absoluteString)
  }

  var body: some View {
    Form {
      Section("Server") {
        TextField("Label", text: $label)
          .onSubmit { saveLabel() }
          .onChange(of: label) { _, newValue in
            // Auto-apply label changes (no validation needed)
            saveLabel()
          }

        TextField("Server URL", text: $serverURL)
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
    }
    .formStyle(.grouped)
  }

  private var isValidURL: Bool {
    guard !serverURL.isEmpty else { return false }
    let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
    return URL(string: urlString) != nil
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
