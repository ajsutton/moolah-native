import Foundation
import OSLog

/// Thin URLSession wrapper that maps HTTP errors to BackendError and handles cookie-based sessions.
final class APIClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    private let logger = Logger(subsystem: "com.moolah.app", category: "APIClient")

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func data(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        
        logger.debug("➡️ \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
        
        // Log outgoing cookie names (hiding values)
        if let url = request.url, let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            let names = cookies.map(\.name).joined(separator: ", ")
            if !names.isEmpty {
                logger.debug("   Sending cookies: \(names)")
            }
        }

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("❌ Network failure: \(error.localizedDescription)")
            throw BackendError.networkUnavailable
        }
        
        guard let http = response as? HTTPURLResponse else {
            logger.error("❌ Non-HTTP response")
            throw BackendError.networkUnavailable
        }
        
        // Log incoming Set-Cookie names
        if let headerFields = http.allHeaderFields as? [String: String],
           let url = http.url {
            let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            let names = responseCookies.map(\.name).joined(separator: ", ")
            if !names.isEmpty {
                logger.debug("   Received cookies: \(names)")
            }
        }
        
        let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("⬅️ \(http.statusCode) \(request.url?.absoluteString ?? "")")
        logger.debug("   Body: \(bodyString)")

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            logger.warning("⚠️ Unauthenticated")
            throw BackendError.unauthenticated
        default:
            logger.error("❌ Server error: \(http.statusCode)")
            throw BackendError.serverError(http.statusCode)
        }
    }

    func get(_ path: String) async throws -> Data {
        let request = URLRequest(url: baseURL.appending(path: path))
        return try await data(for: request)
    }

    func post(_ path: String, body: some Encodable & Sendable) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await data(for: request)
    }

    func delete(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "DELETE"
        return try await data(for: request)
    }
}
