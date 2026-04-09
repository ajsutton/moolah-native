import SwiftUI

/// First-run experience shown when no profiles exist.
/// Lets the user sign in to the default moolah.rocks server or enter a custom URL.
/// Validates the server URL before creating the profile.
struct ProfileSetupView: View {
  @Environment(ProfileStore.self) private var profileStore
  @State private var showCustomServer = false
  @State private var customURL = ""
  @State private var customLabel = ""

  var body: some View {
    VStack(spacing: 32) {
      VStack(spacing: 8) {
        Text("Moolah")
          .font(.largeTitle.bold())
        Text(String(localized: "Personal finance, your way."))
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 12) {
        Button {
          Task { await addDefaultProfile() }
        } label: {
          Label(
            String(localized: "Sign in to Moolah"),
            systemImage: "person.crop.circle.badge.checkmark"
          )
          .frame(maxWidth: 280)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(profileStore.isValidating)

        if !showCustomServer {
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

      if showCustomServer {
        customServerFields
      }

      if profileStore.isValidating {
        ProgressView("Connecting to server...")
      } else if let error = profileStore.validationError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.subheadline)
          .accessibilityLabel("Error: \(error)")
      }
    }
    .padding()
  }

  private var customServerFields: some View {
    VStack(spacing: 12) {
      Divider()
        .frame(maxWidth: 280)

      VStack(alignment: .leading, spacing: 8) {
        TextField("Server URL", text: $customURL)
          .textFieldStyle(.roundedBorder)
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

  private func addDefaultProfile() async {
    let profile = Profile(
      label: "Moolah",
      serverURL: URL(string: "https://moolah.rocks/api/")!
    )
    _ = await profileStore.validateAndAddProfile(profile)
  }

  private func addCustomProfile() async {
    let urlString = customURL.hasPrefix("http") ? customURL : "https://\(customURL)"
    guard let url = URL(string: urlString) else { return }

    let label = customLabel.isEmpty ? url.host() ?? "Custom Server" : customLabel
    let profile = Profile(label: label, serverURL: url)
    _ = await profileStore.validateAndAddProfile(profile)
  }
}
