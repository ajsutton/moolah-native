import SwiftData
import SwiftUI

/// Shared section shown in Moolah and Custom Server profile settings.
/// Provides a button to migrate the profile's data to a new iCloud profile.
struct MigrateToICloudSection: View {
  let profile: Profile
  let session: ProfileSession
  @Binding var showMigration: Bool

  @Environment(\.modelContext) private var modelContext

  var body: some View {
    Section {
      Button {
        showMigration = true
      } label: {
        Label("Migrate to iCloud", systemImage: "icloud.and.arrow.up")
      }
    } footer: {
      Text("Creates a new iCloud profile with a copy of all your data.")
    }
    .sheet(isPresented: $showMigration) {
      MigrationView(
        sourceProfile: profile,
        backend: session.backend,
        modelContainer: modelContext.container
      )
    }
  }
}
