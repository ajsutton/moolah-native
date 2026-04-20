import SwiftUI
import UniformTypeIdentifiers

/// Settings → Import: pick a folder to watch, toggle delete-after-import,
/// and browse import profiles. Device-local settings — not synced.
struct ImportSettingsView: View {
  @Environment(ProfileSession.self) private var session
  @State private var profiles: [CSVImportProfile] = []
  @State private var showFolderPicker = false
  @State private var isReloadingProfiles = false

  var body: some View {
    Form {
      Section("Folder watch") {
        if let path = session.importPreferences.watchedFolderDisplayPath {
          LabeledContent("Watching") {
            Text(path).foregroundStyle(.secondary).lineLimit(2)
          }
          Button("Change folder…") { showFolderPicker = true }
          Button("Stop watching", role: .destructive) {
            session.stopFolderWatch()
          }
        } else {
          Button("Pick folder…") { showFolderPicker = true }
          Text(
            "Pick a folder (usually Downloads) and Moolah will scan it for "
              + "new CSV files at launch, and on macOS watch it live."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Toggle(
          "Delete CSVs after import",
          isOn: Binding(
            get: { session.importPreferences.deleteAfterImportFolderDefault },
            set: { session.importPreferences.deleteAfterImportFolderDefault = $0 }))
      }

      Section("Import profiles") {
        if profiles.isEmpty {
          Text(
            "No profiles yet. Profiles are created automatically when you "
              + "import a CSV into an account."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          ForEach(profiles) { profile in
            VStack(alignment: .leading, spacing: 2) {
              Text(profile.filenamePattern ?? profile.parserIdentifier)
                .font(.subheadline)
              Text(profile.headerSignature.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
              if let lastUsedAt = profile.lastUsedAt {
                Text("Last used \(lastUsedAt, style: .relative) ago")
                  .font(.caption2).foregroundStyle(.secondary)
              }
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                Task { await deleteProfile(profile) }
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("CSV Import")
    .task { await reloadProfiles() }
    .fileImporter(
      isPresented: $showFolderPicker,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      handleFolderPick(result)
    }
  }

  private func reloadProfiles() async {
    isReloadingProfiles = true
    defer { isReloadingProfiles = false }
    do {
      profiles = try await session.backend.csvImportProfiles.fetchAll()
    } catch {
      // Silent log; UI shows empty list.
    }
  }

  private func deleteProfile(_ profile: CSVImportProfile) async {
    try? await session.backend.csvImportProfiles.delete(id: profile.id)
    await reloadProfiles()
  }

  private func handleFolderPick(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      let didStart = url.startAccessingSecurityScopedResource()
      defer {
        if didStart { url.stopAccessingSecurityScopedResource() }
      }
      session.importPreferences.setWatchedFolder(url)
      Task { await session.startFolderWatch() }
    case .failure:
      break
    }
  }
}
