import Foundation

enum BackendType: String, Codable, Sendable {
  case remote
  // Future: case iCloud
}

struct Profile: Identifiable, Codable, Sendable, Equatable {
  let id: UUID
  var label: String
  var backendType: BackendType
  var serverURL: URL
  var cachedUserName: String?
  let createdAt: Date

  init(
    id: UUID = UUID(),
    label: String,
    backendType: BackendType = .remote,
    serverURL: URL,
    cachedUserName: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.backendType = backendType
    self.serverURL = serverURL
    self.cachedUserName = cachedUserName
    self.createdAt = createdAt
  }
}
