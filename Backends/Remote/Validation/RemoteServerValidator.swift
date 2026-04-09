import Foundation

/// Validates a server URL by requesting GET auth/ and checking for valid Moolah JSON.
/// Uses an ephemeral URLSession to avoid polluting any cookie storage.
final class RemoteServerValidator: ServerValidator {
  private let session: URLSession

  init(session: URLSession? = nil) {
    self.session = session ?? URLSession(configuration: .ephemeral)
  }

  func validate(url: URL) async throws {
    let client = APIClient(baseURL: url, session: session)
    let data: Data
    do {
      data = try await client.get("auth/")
    } catch {
      throw BackendError.validationFailed("Could not connect to server")
    }

    struct AuthProbe: Decodable {
      let loggedIn: Bool
    }
    guard (try? JSONDecoder().decode(AuthProbe.self, from: data)) != nil else {
      throw BackendError.validationFailed("Not a valid Moolah server")
    }
  }
}
