import SwiftUI

/// Sheet for adding a new profile (custom server).
struct AddProfileView: View {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(\.dismiss) private var dismiss

  @State private var serverURL = ""
  @State private var label = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Server") {
          TextField("Server URL", text: $serverURL)
            #if os(iOS)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
            #endif

          TextField("Label (optional)", text: $label)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Add Profile")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            addProfile()
          }
          .disabled(!isValidURL)
        }
      }
    }
  }

  private var isValidURL: Bool {
    guard !serverURL.isEmpty else { return false }
    let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
    return URL(string: urlString) != nil
  }

  private func addProfile() {
    let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
    guard let url = URL(string: urlString) else { return }

    let profileLabel = label.isEmpty ? url.host() ?? "Custom Server" : label
    let profile = Profile(label: profileLabel, serverURL: url)
    profileStore.addProfile(profile)
    dismiss()
  }
}
