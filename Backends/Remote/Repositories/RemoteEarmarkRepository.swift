import Foundation
import OSLog

final class RemoteEarmarkRepository: EarmarkRepository, Sendable {
  private let client: APIClient
  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteEarmarkRepository")

  init(client: APIClient) {
    self.client = client
  }

  func fetchAll() async throws -> [Earmark] {
    let data = try await client.get("earmarks/")

    do {
      let wrapper = try JSONDecoder().decode(EarmarkDTO.ListWrapper.self, from: data)
      logger.debug("Successfully decoded \(wrapper.earmarks.count) earmarks")
      return wrapper.earmarks.map { $0.toDomain() }
    } catch {
      logger.error("Decoding error: \(error.localizedDescription)")
      throw error
    }
  }
}
