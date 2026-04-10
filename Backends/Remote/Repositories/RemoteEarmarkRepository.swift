import Foundation
import OSLog

final class RemoteEarmarkRepository: EarmarkRepository, Sendable {
  private let client: APIClient
  private let currency: Currency
  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteEarmarkRepository")

  init(client: APIClient, currency: Currency) {
    self.client = client
    self.currency = currency
  }

  func fetchAll() async throws -> [Earmark] {
    let data = try await client.get("earmarks/")

    do {
      let wrapper = try JSONDecoder().decode(EarmarkDTO.ListWrapper.self, from: data)
      logger.debug("Successfully decoded \(wrapper.earmarks.count) earmarks")
      return wrapper.earmarks.map { $0.toDomain(currency: self.currency) }
    } catch {
      logger.error("Decoding error: \(error.localizedDescription)")
      throw error
    }
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    let dto = CreateEarmarkDTO(from: earmark)
    let data = try await client.post("earmarks/", body: dto)
    let responseDTO = try JSONDecoder().decode(EarmarkDTO.self, from: data)
    return responseDTO.toDomain(currency: currency)
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    let dto = EarmarkDTO.fromDomain(earmark)
    let data = try await client.put("earmarks/\(earmark.id.apiString)/", body: dto)
    let responseDTO = try JSONDecoder().decode(EarmarkDTO.self, from: data)
    return responseDTO.toDomain(currency: currency)
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    let data = try await client.get("earmarks/\(earmarkId.apiString)/budget/")

    do {
      // Server returns { "categoryId1": amount, "categoryId2": amount, ... }
      let dict = try JSONDecoder().decode([String: Int].self, from: data)
      logger.debug("Successfully decoded \(dict.count) budget items")
      return dict.compactMap { (key, value) in
        guard let categoryId = FlexibleUUID.parse(key) else { return nil }
        return EarmarkBudgetItem(
          categoryId: categoryId,
          amount: MonetaryAmount(cents: value, currency: currency)
        )
      }
    } catch {
      logger.error("Decoding error: \(error.localizedDescription)")
      throw error
    }
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: Int) async throws {
    let body = SetBudgetDTO(amount: amount)
    _ = try await client.put(
      "earmarks/\(earmarkId.apiString)/budget/\(categoryId.apiString)/",
      body: body
    )
  }
}

private struct SetBudgetDTO: Codable {
  let amount: Int
}
