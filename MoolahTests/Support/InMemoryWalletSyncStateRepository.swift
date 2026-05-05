import Foundation

@testable import Moolah

/// In-memory `WalletSyncStateRepository` for tests and previews.
///
/// **`@unchecked Sendable` justification.** `states` is a Swift `Dictionary`,
/// not Sendable on its own. `lock` is an `NSLock` and mediates every mutation
/// and read — every method body wraps its access in `lock.withLock`. No state
/// escapes the lock; no mutation happens outside it. This is the standard
/// in-memory test-double pattern used elsewhere in the project (locks +
/// `@unchecked Sendable`, not an `actor`, because the protocol is `async`
/// and the method bodies are synchronous-once-locked).
final class InMemoryWalletSyncStateRepository: WalletSyncStateRepository, @unchecked Sendable {
  private let lock = NSLock()
  private var states: [UUID: WalletSyncState] = [:]

  init(_ initialStates: [WalletSyncState] = []) {
    for state in initialStates {
      states[state.id] = state
    }
  }

  func loadAll() async throws -> [WalletSyncState] {
    lock.withLock { Array(states.values) }
  }

  func load(accountId: UUID) async throws -> WalletSyncState? {
    lock.withLock { states[accountId] }
  }

  func save(_ state: WalletSyncState) async throws {
    lock.withLock { states[state.id] = state }
  }

  func delete(accountId: UUID) async throws {
    lock.withLock { states[accountId] = nil }
  }
}
