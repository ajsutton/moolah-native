#if os(macOS)
  import SwiftUI
  import UniformTypeIdentifiers

  struct ExportImportCommands: Commands {
    let profileStore: ProfileStore
    let containerManager: ProfileContainerManager

    @FocusedValue(\.activeProfileSession) private var session

    var body: some Commands {
      CommandGroup(after: .saveItem) {
        Divider()

        Button("Export Profile\u{2026}") {
          guard let session else { return }
          Task { await exportProfile(session: session) }
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(session == nil)

        Button("Import Profile\u{2026}") {
          Task { await importProfile() }
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
      }
    }

    @MainActor
    private func exportProfile(session: ProfileSession) async {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "\(session.profile.label).json"
      panel.canCreateDirectories = true

      guard panel.runModal() == .OK, let url = panel.url else { return }

      let coordinator = MigrationCoordinator()
      do {
        try await coordinator.exportToFile(
          url: url,
          backend: session.backend,
          profile: session.profile
        )
      } catch {
        let alert = NSAlert(error: error)
        alert.runModal()
      }
    }

    @MainActor
    private func importProfile() async {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.json]
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false

      guard panel.runModal() == .OK, let url = panel.url else { return }

      let jsonData: Data
      let exported: ExportedData
      do {
        jsonData = try Data(contentsOf: url)
        exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
      } catch {
        let alert = NSAlert(error: error)
        alert.runModal()
        return
      }

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
          modelContainer: container
        )
        profileStore.setActiveProfile(newProfile.id)
      } catch {
        profileStore.removeProfile(newProfile.id)
        let alert = NSAlert(error: error)
        alert.runModal()
      }
    }
  }
#endif
