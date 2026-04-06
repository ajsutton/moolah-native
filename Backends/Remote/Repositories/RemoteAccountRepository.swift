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
}
