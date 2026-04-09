import SwiftUI

/// Unified form for adding or editing a profile.
/// Shows server URL validation errors inline and prevents submission until valid.
struct ProfileFormView: View {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(\.dismiss) private var dismiss

  let existingProfile: Profile?

  @State private var serverURL: String
  @State private var label: String

  init(profile: Profile? = nil) {
    self.existingProfile = profile
    _serverURL = State(initialValue: profile?.serverURL.absoluteString ?? "")
    _label = State(initialValue: profile?.label ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Server") {
          TextField("Server URL", text: $serverURL)
            #if os(iOS)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
            #endif
            .onChange(of: serverURL) {
              profileStore.clearValidationError()
            }

          TextField("Label (optional)", text: $label)
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
      .navigationTitle(existingProfile == nil ? "Add Profile" : "Edit Profile")
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
            ProgressView()
              .controlSize(.small)
          } else {
            Button(existingProfile == nil ? "Add" : "Save") {
              Task { await save() }
            }
            .disabled(!isValidURL)
          }
        }
      }
    }
  }

  private var isValidURL: Bool {
    guard !serverURL.isEmpty else { return false }
    let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
    return URL(string: urlString) != nil
  }

  private func save() async {
    let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
    guard let url = URL(string: urlString) else { return }
    let profileLabel = label.isEmpty ? url.host() ?? "Custom Server" : label

    if var existing = existingProfile {
      existing.serverURL = url
      existing.label = profileLabel
      if await profileStore.validateAndUpdateProfile(existing) {
        dismiss()
      }
    } else {
      let profile = Profile(label: profileLabel, serverURL: url)
      if await profileStore.validateAndAddProfile(profile) {
        dismiss()
      }
    }
  }
}
