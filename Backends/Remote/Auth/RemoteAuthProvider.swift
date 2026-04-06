#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Foundation

/// Authenticates via the Moolah REST server's Google OAuth flow.
///
/// Sign-in flow:
/// 1. Generates a random nonce and opens
///    `<baseURL>googleauth?_native=1&_nonce=<nonce>` in the system browser.
/// 2. The user completes Google sign-in. The server stores the session
///    keyed by the nonce and shows a "sign-in complete" page.
/// 3. Meanwhile the app polls `POST /api/auth/token` with the nonce
///    until the server returns the session, then sets the cookie.
@MainActor
final class RemoteAuthProvider: AuthProvider {
    nonisolated let requiresExplicitSignIn = true

    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func currentUser() async throws -> UserProfile? {
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
