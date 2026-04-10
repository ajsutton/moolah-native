import Foundation

/// A UUID wrapper that always serializes to lowercase strings for server communication.
/// Use this for all ID fields in DTOs to prevent case-mismatch bugs between
/// Swift (uppercase) and the server (lowercase).
struct ServerUUID: Codable, Hashable, Sendable {
  let uuid: UUID

  init(_ uuid: UUID) {
    self.uuid = uuid
  }

  var uuidString: String {
    uuid.uuidString.lowercased()
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(uuidString)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let parsed = FlexibleUUID.parse(string) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid UUID string: \(string)"
      )
    }
    self.uuid = parsed
  }
}

extension UUID {
  /// Lowercase UUID string for server API communication.
  /// Use this instead of `uuidString` when constructing URL paths or query parameters.
  var apiString: String {
    uuidString.lowercased()
  }
}
