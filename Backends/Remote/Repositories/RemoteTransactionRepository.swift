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

    if let scheduled = filter.scheduled {
      queryItems.append(URLQueryItem(name: "scheduled", value: String(scheduled)))
    }

    let data = try await client.get("transactions/", queryItems: queryItems)

    do {
      let wrapper = try JSONDecoder().decode(TransactionDTO.ListWrapper.self, from: data)
      logger.debug("Successfully decoded \(wrapper.transactions.count) transactions")
      return TransactionPage(
        transactions: wrapper.transactions.map { $0.toDomain() },
        priorBalance: wrapper.priorBalance
      )
    } catch {
      logger.error("Decoding error: \(error.localizedDescription)")
      throw error
    }
  }
}
