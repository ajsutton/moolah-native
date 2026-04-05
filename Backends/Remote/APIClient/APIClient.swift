import Foundation

/// Thin URLSession wrapper that maps HTTP errors to BackendError and handles cookie-based sessions.
final class APIClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func data(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.networkUnavailable
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw BackendError.unauthenticated
        default:
            throw BackendError.serverError(http.statusCode)
        }
    }

    func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        return try await data(for: request)
    }

    func delete(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "DELETE"
        return try await data(for: request)
    }
}
