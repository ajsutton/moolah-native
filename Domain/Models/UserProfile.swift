import Foundation

/// A signed-in user's identity as returned by the server.
/// Server JSON fields: userId, givenName, familyName, picture
struct UserProfile: Codable, Sendable, Equatable {
    let id: String
    let givenName: String
    let familyName: String
    let pictureURL: URL?

    enum CodingKeys: String, CodingKey {
        case id = "userId"
        case givenName
        case familyName
        case pictureURL = "picture"
    }
}
