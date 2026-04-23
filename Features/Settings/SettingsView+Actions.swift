import SwiftUI
import UniformTypeIdentifiers

// Import / export handlers and delete-alert chrome extracted from
// `SettingsView` so the main struct body stays under SwiftLint's
// `type_body_length` threshold.
extension SettingsView {

  // MARK: - Import

  func handleImport(result: Result<URL, Error>) async {
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
    func handleExport(profile: Profile) async {
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

  func profileRow(_ profile: Profile) -> some View {
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

  var deleteAlertTitle: String {
    if let profile = profileToDelete, profile.backendType == .cloudKit {
      return "Delete \(profile.label)?"
    }
    return "Remove Profile?"
  }

  @ViewBuilder var deleteAlertButtons: some View {
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

  @ViewBuilder var deleteAlertMessage: some View {
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
