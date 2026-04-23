import SwiftUI

// Per-backend profile detail views + shared auth status row, extracted
// from `SettingsView.swift` so the main settings file stays under
// SwiftLint's `file_length` threshold. `SettingsView.profileDetailView(for:)`
// routes to one of the three backend detail views here; each maintains its
// own form state and persists changes back through `ProfileStore`.

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
