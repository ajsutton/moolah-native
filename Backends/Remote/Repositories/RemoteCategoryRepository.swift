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

  func create(_ category: Category) async throws -> Category {
    let dto = CategoryDTO.fromDomain(category)
    let data = try await client.post("categories/", body: dto)
    let responseDTO = try JSONDecoder().decode(CategoryDTO.self, from: data)
    return responseDTO.toDomain()
  }

  func update(_ category: Category) async throws -> Category {
    let dto = CategoryDTO.fromDomain(category)
    let data = try await client.put("categories/\(category.id.apiString)/", body: dto)
    let responseDTO = try JSONDecoder().decode(CategoryDTO.self, from: data)
    return responseDTO.toDomain()
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    var queryItems: [URLQueryItem] = []
    if let replacementId = replacementId {
      queryItems.append(URLQueryItem(name: "replacement", value: replacementId.apiString))
    }
    _ = try await client.delete("categories/\(id.apiString)/", queryItems: queryItems)
  }
}
