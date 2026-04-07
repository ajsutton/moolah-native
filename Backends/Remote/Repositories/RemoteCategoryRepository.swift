import Foundation
import OSLog

final class RemoteCategoryRepository: CategoryRepository, Sendable {
  private let client: APIClient
  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteCategoryRepository")

  init(client: APIClient) {
    self.client = client
  }

  func fetchAll() async throws -> [Category] {
    let data = try await client.get("categories/")

    do {
      let wrapper = try JSONDecoder().decode(CategoryDTO.ListWrapper.self, from: data)
      logger.debug("Successfully decoded \(wrapper.categories.count) categories")
      return wrapper.categories.map { $0.toDomain() }
    } catch {
      logger.error("❌ Decoding error: \(error.localizedDescription)")
      throw error
    }
  }
}
