import SwiftUI

/// Sheet for adding a new profile. Presents three choices:
/// - iCloud (local-only with CloudKit sync)
/// - Moolah (fixed URL, instant add)
/// - Custom Server (user enters URL)
struct ProfileFormView: View {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(\.dismiss) private var dismiss

  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
  #endif

  @State private var selectedType: BackendType?
  @State private var serverURL = ""
  @State private var label = ""

  // iCloud profile fields
  @State private var cloudName = ""
  @State private var cloudCurrencyCode = Locale.current.currency?.identifier ?? "AUD"
  @State private var cloudFinancialYearStartMonth = 7

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  var body: some View {
    NavigationStack {
      form
    }
  }

  private var form: some View {
    Form {
      backendTypeSection
      if selectedType == .cloudKit {
        cloudKitSection
      }
      if selectedType == .remote {
        remoteSection
      }
      if let error = profileStore.validationError {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(error)")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Add Profile")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          profileStore.clearValidationError()
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        if profileStore.isValidating {
          ProgressView().controlSize(.small)
        } else {
          Button("Add") { Task { await save() } }
            .disabled(!canAdd)
        }
      }
    }
  }

  private var backendTypeSection: some View {
    Section {
      backendTypeButton(.cloudKit, label: "iCloud", systemImage: "icloud")
      backendTypeButton(.moolah, label: "Moolah", systemImage: "cloud")
      backendTypeButton(.remote, label: "Custom Server", systemImage: "server.rack")
    }
  }

  private func backendTypeButton(
    _ type: BackendType, label: String, systemImage: String
  ) -> some View {
    Button {
      selectedType = type
    } label: {
      HStack {
        Label(label, systemImage: systemImage)
        Spacer()
        if selectedType == type {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selectedType == type ? .isSelected : [])
  }

  private var cloudKitSection: some View {
    Section("Profile") {
      TextField("Name", text: $cloudName)
      CurrencyPicker(selection: $cloudCurrencyCode)
      Picker("Financial Year Starts", selection: $cloudFinancialYearStartMonth) {
        ForEach(1...12, id: \.self) { month in
          if month <= Self.monthNames.count {
            Text(Self.monthNames[month - 1]).tag(month)
          }
        }
      }
    }
  }

  private var remoteSection: some View {
    Section("Server") {
      TextField("Server URL", text: $serverURL)
        .autocorrectionDisabled()
        #if os(iOS)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
        #endif
        .onChange(of: serverURL) {
          profileStore.clearValidationError()
        }
      TextField("Label (optional)", text: $label)
    }
  }

  private var canAdd: Bool {
    guard let type = selectedType else { return false }
    switch type {
    case .moolah:
      return true
    case .remote:
      guard !serverURL.isEmpty else { return false }
      let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
      return URL(string: urlString) != nil
    case .cloudKit:
      return !cloudName.trimmingCharacters(in: .whitespaces).isEmpty
    }
  }

  private func save() async {
    guard let type = selectedType else { return }

    let profile: Profile
    switch type {
    case .moolah:
      profile = Profile(label: "Moolah", backendType: .moolah)
    case .remote:
      let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
      guard let url = URL(string: urlString) else { return }
      let profileLabel = label.isEmpty ? url.host() ?? "Custom Server" : label
      profile = Profile(label: profileLabel, backendType: .remote, serverURL: url)
    case .cloudKit:
      let trimmedName = cloudName.trimmingCharacters(in: .whitespaces)
      profile = Profile(
        label: trimmedName,
        backendType: .cloudKit,
        currencyCode: cloudCurrencyCode,
        financialYearStartMonth: cloudFinancialYearStartMonth
      )
    }

    if await profileStore.validateAndAddProfile(profile) {
      #if os(macOS)
        openWindow(value: profile.id)
      #else
        profileStore.setActiveProfile(profile.id)
      #endif
      dismiss()
    }
  }

}
