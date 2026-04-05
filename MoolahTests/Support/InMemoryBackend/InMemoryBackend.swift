import Foundation
@testable import Moolah

/// Full in-memory implementation of BackendProvider.
/// Grows a property each time a new repository protocol is introduced.
final class InMemoryBackend: BackendProvider, @unchecked Sendable {
    let auth: any AuthProvider

    init(auth: any AuthProvider = InMemoryAuthProvider()) {
        self.auth = auth
    }
}
