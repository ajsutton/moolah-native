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

  func create(_ earmark: Earmark) async throws -> Earmark {
    let dto = EarmarkDTO.fromDomain(earmark)
    let data = try await client.post("earmarks/", body: dto)
    let responseDTO = try JSONDecoder().decode(EarmarkDTO.self, from: data)
    return responseDTO.toDomain()
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    let dto = EarmarkDTO.fromDomain(earmark)
    let data = try await client.put("earmarks/\(earmark.id.uuidString)/", body: dto)
    let responseDTO = try JSONDecoder().decode(EarmarkDTO.self, from: data)
    return responseDTO.toDomain()
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    let data = try await client.get("earmarks/\(earmarkId.uuidString)/budget/")

    do {
      let wrapper = try JSONDecoder().decode(EarmarkBudgetItemDTO.ListWrapper.self, from: data)
      logger.debug("Successfully decoded \(wrapper.budget.count) budget items")
      return wrapper.budget.map { $0.toDomain() }
    } catch {
      logger.error("Decoding error: \(error.localizedDescription)")
      throw error
    }
  }

  func updateBudget(earmarkId: UUID, items: [EarmarkBudgetItem]) async throws {
    let dtos = items.map { EarmarkBudgetItemDTO.fromDomain($0) }
    let wrapper = EarmarkBudgetItemDTO.ListWrapper(budget: dtos)
    _ = try await client.put("earmarks/\(earmarkId.uuidString)/budget/", body: wrapper)
  }
}
