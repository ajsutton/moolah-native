import Foundation

/// In-memory CSV import profile repository used by the REST backend. CSV
/// import is a client-only feature — the server has no notion of profiles —
/// so the remote path keeps them in memory. When the user switches to the
/// CloudKit backend, profiles live in the synced store instead.
actor RemoteCSVImportProfileRepository: CSVImportProfileRepository {
  private var profiles: [UUID: CSVImportProfile] = [:]

  func fetchAll() async throws -> [CSVImportProfile] {
    profiles.values.sorted { $0.createdAt < $1.createdAt }
  }

  func create(_ profile: CSVImportProfile) async throws -> CSVImportProfile {
    profiles[profile.id] = profile
    return profile
  }

  func update(_ profile: CSVImportProfile) async throws -> CSVImportProfile {
    guard profiles[profile.id] != nil else {
      throw BackendError.serverError(404)
    }
    profiles[profile.id] = profile
    return profile
  }

  func delete(id: UUID) async throws {
    guard profiles.removeValue(forKey: id) != nil else {
      throw BackendError.serverError(404)
    }
  }
}
