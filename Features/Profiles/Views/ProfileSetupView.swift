import SwiftUI

/// First-run experience shown when no profiles exist.
/// Offers iCloud (recommended), Moolah server, or a custom server URL.
/// Validates availability/connectivity before creating the profile.
struct ProfileSetupView: View {
  @Environment(ProfileStore.self) private var profileStore
  @State private var showCustomServer = false
  @State private var customURL = ""
  @State private var customLabel = ""

  // iCloud profile fields
  @State private var showICloudForm = false
  @State private var cloudName = ""
  @State private var cloudCurrencyCode = Locale.current.currency?.identifier ?? "AUD"
  @State private var cloudFinancialYearStartMonth = 7

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  var body: some View {
    ScrollView {
      VStack(spacing: 32) {
        VStack(spacing: 8) {
          Text("Moolah")
            .font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
          Text(String(localized: "Personal finance, your way."))
            .foregroundStyle(.secondary)
        }

        VStack(spacing: 12) {
          if !showICloudForm {
            Button {
              withAnimation { showICloudForm = true }
            } label: {
              Label(
                String(localized: "Store in iCloud"),
                systemImage: "icloud"
              )
              .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(profileStore.isValidating)
          }

          if showICloudForm {
            Button {
              Task { await addDefaultProfile() }
            } label: {
              Label(
                String(localized: "Connect to Moolah"),
                systemImage: "link"
              )
              .frame(maxWidth: 280)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(profileStore.isValidating)
          } else {
            Button {
              Task { await addDefaultProfile() }
            } label: {
              Label(
                String(localized: "Connect to Moolah"),
                systemImage: "link"
              )
              .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(profileStore.isValidating)
          }

          if !showCustomServer && !showICloudForm {
            Button {
              withAnimation { showCustomServer = true }
            } label: {
              Text(String(localized: "Use a custom server"))
                .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
          }
        }

        if showICloudForm {
          iCloudFields
        }

        if showCustomServer {
          customServerFields
        }

        if profileStore.isValidating {
          ProgressView("Connecting...")
            .accessibilityAddTraits(.updatesFrequently)
        } else if let error = profileStore.validationError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.subheadline)
            .accessibilityLabel("Error: \(error)")
        }
      }
      .padding()
    }
  }

  // MARK: - iCloud Fields

  private var iCloudFields: some View {
    VStack(spacing: 12) {
      Divider()
        .frame(maxWidth: 280)

      VStack(alignment: .leading, spacing: 8) {
        TextField("Profile Name", text: $cloudName)
          .textFieldStyle(.roundedBorder)

        CurrencyPicker(selection: $cloudCurrencyCode)

        Picker("Financial Year Starts", selection: $cloudFinancialYearStartMonth) {
          ForEach(1...12, id: \.self) { month in
            if month <= Self.monthNames.count {
              Text(Self.monthNames[month - 1])
                .tag(month)
            }
          }
        }
      }
      .frame(maxWidth: 280)

      Button {
        Task { await addICloudProfile() }
      } label: {
        Label(String(localized: "Create"), systemImage: "icloud")
          .frame(maxWidth: 280)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(
        cloudName.trimmingCharacters(in: .whitespaces).isEmpty || profileStore.isValidating)
    }
  }

  // MARK: - Custom Server Fields

  private var customServerFields: some View {
    VStack(spacing: 12) {
      Divider()
        .frame(maxWidth: 280)

      VStack(alignment: .leading, spacing: 8) {
        TextField("Server URL", text: $customURL)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
          #endif
          .onChange(of: customURL) {
            profileStore.clearValidationError()
          }

        TextField("Label (optional)", text: $customLabel)
          .textFieldStyle(.roundedBorder)
      }
      .frame(maxWidth: 280)

      Button {
        Task { await addCustomProfile() }
      } label: {
        Text(String(localized: "Connect"))
          .frame(maxWidth: 280)
      }
      #if os(macOS)
        .buttonStyle(.bordered)
      #else
        .buttonStyle(.borderedProminent)
      #endif
      .controlSize(.large)
      .disabled(!isValidURL || profileStore.isValidating)
    }
  }

  private var isValidURL: Bool {
    guard !customURL.isEmpty else { return false }
    let urlString = customURL.hasPrefix("http") ? customURL : "https://\(customURL)"
    return URL(string: urlString) != nil
  }

  // MARK: - Actions

  private func addICloudProfile() async {
    let trimmedName = cloudName.trimmingCharacters(in: .whitespaces)
    let profile = Profile(
      label: trimmedName,
      backendType: .cloudKit,
      currencyCode: cloudCurrencyCode,
      financialYearStartMonth: cloudFinancialYearStartMonth
    )
    _ = await profileStore.validateAndAddProfile(profile)
  }

  private func addDefaultProfile() async {
    let profile = Profile(
      label: "Moolah",
      backendType: .moolah
    )
    _ = await profileStore.validateAndAddProfile(profile)
  }

  private func addCustomProfile() async {
    let urlString = customURL.hasPrefix("http") ? customURL : "https://\(customURL)"
    guard let url = URL(string: urlString) else { return }

    let label = customLabel.isEmpty ? url.host() ?? "Custom Server" : customLabel
    let profile = Profile(label: label, backendType: .remote, serverURL: url)
    _ = await profileStore.validateAndAddProfile(profile)
  }
}
