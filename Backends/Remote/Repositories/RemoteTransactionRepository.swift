import Foundation
import OSLog

final class RemoteTransactionRepository: TransactionRepository, Sendable {
  private let client: APIClient
  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteTransactionRepository")

  init(client: APIClient) {
    self.client = client
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    var queryItems: [URLQueryItem] = []

    queryItems.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
    queryItems.append(URLQueryItem(name: "offset", value: String(page * pageSize)))

    if let accountId = filter.accountId {
      queryItems.append(URLQueryItem(name: "account", value: accountId.uuidString))
    }

    if let earmarkId = filter.earmarkId {
      queryItems.append(URLQueryItem(name: "earmark", value: earmarkId.uuidString))
    }

    if let scheduled = filter.scheduled {
      queryItems.append(URLQueryItem(name: "scheduled", value: String(scheduled)))
    }

    if let dateRange = filter.dateRange {
      queryItems.append(
        URLQueryItem(
          name: "startDate", value: BackendDateFormatter.string(from: dateRange.lowerBound)))
      queryItems.append(
        URLQueryItem(
          name: "endDate", value: BackendDateFormatter.string(from: dateRange.upperBound)))
    }

    if let categoryIds = filter.categoryIds, !categoryIds.isEmpty {
      for categoryId in categoryIds {
        queryItems.append(URLQueryItem(name: "category", value: categoryId.uuidString))
      }
    }

    if let payee = filter.payee, !payee.isEmpty {
      queryItems.append(URLQueryItem(name: "payee", value: payee))
    }

    let data = try await client.get("transactions/", queryItems: queryItems)

    do {
      let wrapper = try JSONDecoder().decode(TransactionDTO.ListWrapper.self, from: data)
      logger.debug("Successfully decoded \(wrapper.transactions.count) transactions")
      return TransactionPage(
        transactions: wrapper.transactions.map { $0.toDomain() },
        priorBalance: MonetaryAmount(
          cents: wrapper.priorBalance, currency: Currency.defaultCurrency)
      )
    } catch {
      logger.error("Decoding error: \(error.localizedDescription)")
      throw error
    }
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    let dto = CreateTransactionDTO.fromDomain(transaction)
    let data = try await client.post("transactions/", body: dto)
    let responseDTO = try JSONDecoder().decode(TransactionDTO.self, from: data)
    return responseDTO.toDomain()
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    let dto = TransactionDTO.fromDomain(transaction)
    let data = try await client.put("transactions/\(transaction.id.uuidString)/", body: dto)
    let responseDTO = try JSONDecoder().decode(TransactionDTO.self, from: data)
    return responseDTO.toDomain()
  }

  func delete(id: UUID) async throws {
    _ = try await client.delete("transactions/\(id.uuidString)/")
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    // The server has no dedicated payee suggestion endpoint.
    // Query transactions filtered by payee substring and extract unique payees.
    var queryItems = [URLQueryItem(name: "payee", value: prefix)]
    queryItems.append(URLQueryItem(name: "pageSize", value: "100"))
    queryItems.append(URLQueryItem(name: "offset", value: "0"))

    let data = try await client.get("transactions/", queryItems: queryItems)
    let wrapper = try JSONDecoder().decode(TransactionDTO.ListWrapper.self, from: data)
    let payees = Set(wrapper.transactions.compactMap(\.payee).filter { !$0.isEmpty })
    return payees.sorted()
  }
}
