import Foundation

protocol AccountRepository: Sendable {
  func fetchAll() async throws -> [Account]
  func create(_ account: Account, openingBalance: InstrumentAmount?) async throws -> Account
  func update(_ account: Account) async throws -> Account
  func delete(id: UUID) async throws
}

extension AccountRepository {
  func create(_ account: Account) async throws -> Account {
    try await create(account, openingBalance: nil)
  }
}
