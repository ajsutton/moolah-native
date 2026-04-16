import Foundation

/// A signed-in user's identity as returned by the server.
/// Server JSON fields: userId, picture
struct UserProfile: Codable, Sendable, Equatable {
  let id: String
  let pictureURL: URL?

  enum CodingKeys: String, CodingKey {
    case id = "userId"
    case pictureURL = "picture"
  }
}
