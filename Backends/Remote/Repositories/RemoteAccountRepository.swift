import Foundation
import OSLog

final class RemoteAccountRepository: AccountRepository, Sendable {
  private let client: APIClient
  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteAccountRepository")

  init(client: APIClient) {
    self.client = client
  }

  func fetchAll() async throws -> [Account] {
    // The moolah-server expects a trailing slash: /api/accounts/
    let data = try await client.get("accounts/")

    do {
      let wrapper = try JSONDecoder().decode(AccountDTO.ListWrapper.self, from: data)
      logger.debug("Successfully decoded \(wrapper.accounts.count) accounts")
      return wrapper.accounts.map { $0.toDomain() }
    } catch {
      logger.error("❌ Decoding error: \(error.localizedDescription)")
      if let decodingError = error as? DecodingError {
        switch decodingError {
        case .keyNotFound(let key, let context):
          logger.error(
            "   Key not found: \(key.stringValue) (context: \(context.debugDescription))")
        case .typeMismatch(let type, let context):
          logger.error(
            "   Type mismatch: expected \(String(describing: type)) (context: \(context.debugDescription))"
          )
        case .valueNotFound(let type, let context):
          logger.error(
            "   Value not found: \(String(describing: type)) (context: \(context.debugDescription))"
          )
        case .dataCorrupted(let context):
          logger.error("   Data corrupted: \(context.debugDescription)")
        @unknown default:
          logger.error("   Unknown decoding error")
        }
      }
      throw error
    }
  }

  func create(_ account: Account) async throws -> Account {
    // Validation
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    let dto = CreateAccountDTO(
      name: account.name,
      type: account.type.rawValue,
      balance: account.balance.cents,
      position: account.position,
      date: ISO8601DateFormatter().string(from: Date())  // Today
    )

    let data = try await client.post("accounts/", body: dto)

    do {
      let response = try JSONDecoder().decode(AccountDTO.self, from: data)
      logger.debug("Successfully created account: \(response.name)")
      return response.toDomain()
    } catch {
      logger.error("❌ Decoding error: \(error.localizedDescription)")
      throw error
    }
  }

  func update(_ account: Account) async throws -> Account {
    // Validation
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    let dto = UpdateAccountDTO(
      id: account.id.uuidString.lowercased(),
      name: account.name,
      type: account.type.rawValue,
      position: account.position,
      hidden: account.isHidden
    )

    let data = try await client.put("accounts/\(account.id.uuidString.lowercased())/", body: dto)

    do {
      let response = try JSONDecoder().decode(AccountDTO.self, from: data)
      logger.debug("Successfully updated account: \(response.name)")
      return response.toDomain()  // Accept server's balance
    } catch {
      logger.error("❌ Decoding error: \(error.localizedDescription)")
      throw error
    }
  }

  func delete(id: UUID) async throws {
    // Soft delete via update - first fetch the account
    let allAccounts = try await fetchAll()
    guard let account = allAccounts.first(where: { $0.id == id }) else {
      throw BackendError.notFound("Account not found")
    }

    guard account.balance.cents == 0 else {
      throw BackendError.validationFailed("Cannot delete account with non-zero balance")
    }

    var updated = account
    updated.isHidden = true
    _ = try await update(updated)
  }
}
