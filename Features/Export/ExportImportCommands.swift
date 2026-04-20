#if os(macOS)
  import OSLog
  import SwiftUI
  import UniformTypeIdentifiers

  /// Export/Import buttons for use inside a CommandGroup.
  struct ExportImportButtons: View {
    let profileStore: ProfileStore
    let containerManager: ProfileContainerManager
    let syncCoordinator: SyncCoordinator
    let session: ProfileSession?

    @Environment(\.openWindow) private var openWindow

    private let logger = Logger(subsystem: "com.moolah.app", category: "Export")

    var body: some View {
      Button("Export Profile\u{2026}") {
        guard let session else { return }
        logger.info("Export: starting for profile \(session.profile.label, privacy: .public)")
        Task { await exportProfile(session: session) }
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(session == nil)

      Button("Import Profile\u{2026}") {
        Task { await importProfile() }
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
    }

    @MainActor
    private func exportProfile(session: ProfileSession) async {
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        logger.error("Export: no window available")
        return
      }

      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "\(session.profile.label).json"
      panel.canCreateDirectories = true

      let result = await panel.beginSheetModal(for: window)
      guard result == .OK, let url = panel.url else { return }

      logger.info("Export: saving to \(url.path, privacy: .public)")
      let coordinator = MigrationCoordinator()
      do {
        try await coordinator.exportToFile(
          url: url,
          backend: session.backend,
          profile: session.profile
        )
        logger.info("Export: complete — saved to \(url.path, privacy: .public)")
      } catch {
        logger.error("Export: failed — \(error)")
        let alert = NSAlert(error: error)
        await alert.beginSheetModal(for: window)
      }
    }

    @MainActor
    private func importProfile() async {
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        logger.error("Import: no window available")
        return
      }

      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.json]
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false

      guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }

      let jsonData: Data
      let exported: ExportedData
      do {
        jsonData = try Data(contentsOf: url)
        exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
      } catch {
        let alert = NSAlert(error: error)
        await alert.beginSheetModal(for: window)
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
          modelContainer: container,
          profileId: newProfile.id,
          syncCoordinator: syncCoordinator
        )
        openWindow(value: newProfile.id)
      } catch {
        containerManager.deleteStore(for: newProfile.id)
        profileStore.removeProfile(newProfile.id)
        let alert = NSAlert(error: error)
        await alert.beginSheetModal(for: window)
      }
    }
  }
#endif
