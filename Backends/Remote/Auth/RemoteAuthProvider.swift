#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Foundation
import OSLog

/// Authenticates via the Moolah REST server's Google OAuth flow.
@MainActor
final class RemoteAuthProvider: AuthProvider {
    nonisolated let requiresExplicitSignIn = true

    private let client: APIClient
    private let cookieKeychain: CookieKeychain
    private var hasRestoredCookies = false
    private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteAuthProvider")

    init(client: APIClient, cookieKeychain: CookieKeychain = CookieKeychain()) {
        self.client = client
        self.cookieKeychain = cookieKeychain
    }

    func currentUser() async throws -> UserProfile? {
        if !hasRestoredCookies {
            hasRestoredCookies = true
            restoreCookiesIfNeeded()
        }

        do {
            let data = try await client.get("auth/")
            let response = try JSONDecoder().decode(LoginStateResponse.self, from: data)
            guard response.loggedIn, let profile = response.profile else { return nil }
            return UserProfile(
                id: profile.userId,
                givenName: profile.givenName,
                familyName: profile.familyName,
                pictureURL: profile.picture.flatMap { URL(string: $0) }
            )
        } catch BackendError.unauthenticated {
            return nil
        }
    }

    func signIn() async throws -> UserProfile {
        let nonce = UUID().uuidString

        var components = URLComponents(url: client.baseURL.appending(path: "googleauth"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "_native", value: "1"),
            URLQueryItem(name: "_nonce", value: nonce),
        ]
        let authURL = components.url!

        #if os(macOS)
        NSWorkspace.shared.open(authURL)
        #elseif os(iOS)
        await UIApplication.shared.open(authURL)
        #endif

        // Poll until the server has stored the session for our nonce.
        let body = TokenExchangeRequest(code: nonce)
        let deadline = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))

            let data = try await client.post("auth/token", body: body)
            let response = try JSONDecoder().decode(LoginStateResponse.self, from: data)
            if response.loggedIn, let profile = response.profile {
                saveCookies()
                return UserProfile(
                    id: profile.userId,
                    givenName: profile.givenName,
                    familyName: profile.familyName,
                    pictureURL: profile.picture.flatMap { URL(string: $0) }
                )
            }
        }
        throw BackendError.unauthenticated
    }

    func signOut() async throws {
        _ = try await client.delete("auth/")
        cookieKeychain.clear()
        clearCookieStorage()
    }

    // MARK: - Cookie Persistence

    private func serverCookies(in storage: HTTPCookieStorage) -> [HTTPCookie] {
        guard let host = client.baseURL.host() else { return [] }
        return (storage.cookies ?? []).filter { $0.domain == host || $0.domain == ".\(host)" }
    }

    private func saveCookies() {
        let storage = HTTPCookieStorage.shared
        let cookies = serverCookies(in: storage)
        guard !cookies.isEmpty else { 
            logger.warning("No cookies found to save")
            return 
        }
        
        // Ensure cookies have path "/" so they match all API endpoints.
        let massagedCookies = cookies.compactMap { massageCookie($0) }

        do {
            try cookieKeychain.save(cookies: massagedCookies)
            let names = massagedCookies.map(\.name).joined(separator: ", ")
            logger.debug("Saved \(massagedCookies.count) cookies to keychain: \(names)")
            
            // Update storage with massaged cookies too
            for cookie in massagedCookies {
                storage.setCookie(cookie)
            }
        } catch {
            logger.error("❌ Failed to save cookies: \(error.localizedDescription)")
        }
    }

    private func restoreCookiesIfNeeded() {
        let storage = HTTPCookieStorage.shared
        let existing = serverCookies(in: storage)
        guard existing.isEmpty else { 
            logger.debug("Already have \(existing.count) cookies in storage, skipping restore")
            return 
        }

        do {
            guard let cookies = try cookieKeychain.restore() else { 
                logger.debug("No cookies found in keychain to restore")
                return 
            }
            
            let massagedCookies = cookies.compactMap { massageCookie($0) }
            let names = massagedCookies.map(\.name).joined(separator: ", ")
            logger.debug("Restoring \(massagedCookies.count) cookies from keychain: \(names)")
            for cookie in massagedCookies {
                storage.setCookie(cookie)
            }
        } catch {
            logger.error("❌ Failed to restore cookies: \(error.localizedDescription)")
        }
    }

    private func massageCookie(_ cookie: HTTPCookie) -> HTTPCookie? {
        guard var props = cookie.properties else { return cookie }
        if props[.path] as? String != "/" {
            logger.debug("Massaging cookie path: \(cookie.name) (\(cookie.path) -> /)")
            props[.path] = "/"
            return HTTPCookie(properties: props)
        }
        return cookie
    }

    private func clearCookieStorage() {
        let storage = HTTPCookieStorage.shared
        for cookie in serverCookies(in: storage) {
            storage.deleteCookie(cookie)
        }
        logger.debug("Cleared cookie storage")
    }
}

// MARK: - Private DTOs

private struct TokenExchangeRequest: Encodable {
    let code: String
}

private struct LoginStateResponse: Decodable {
    let loggedIn: Bool
    let profile: ProfilePayload?

    struct ProfilePayload: Decodable {
        let userId: String
        let givenName: String
        let familyName: String
        let picture: String?
    }
}
