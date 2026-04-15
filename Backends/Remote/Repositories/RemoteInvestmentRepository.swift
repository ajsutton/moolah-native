import Foundation
import OSLog

final class RemoteInvestmentRepository: InvestmentRepository, Sendable {
  private let client: APIClient
  private let instrument: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteInvestmentRepository")

  init(client: APIClient, instrument: Instrument) {
    self.client = client
    self.instrument = instrument
  }

  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage {
    let queryItems = [
      URLQueryItem(name: "pageSize", value: String(pageSize)),
      URLQueryItem(name: "offset", value: String(page * pageSize)),
    ]

    let path = "accounts/\(accountId.apiString)/values/"
    let data = try await client.get(path, queryItems: queryItems)
    let wrapper = try JSONDecoder().decode(InvestmentValueDTO.ListWrapper.self, from: data)

    return InvestmentValuePage(
      values: wrapper.values.map { $0.toDomain(instrument: instrument) },
      hasMore: wrapper.hasMore
    )
  }

  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async throws {
    let dateString = BackendDateFormatter.string(from: date)
    let path = "accounts/\(accountId.apiString)/values/\(dateString)"
    let cents = Int(truncating: (value.quantity * 100) as NSDecimalNumber)
    _ = try await client.put(path, body: cents)
  }

  func removeValue(accountId: UUID, date: Date) async throws {
    let dateString = BackendDateFormatter.string(from: date)
    let path = "accounts/\(accountId.apiString)/values/\(dateString)"
    _ = try await client.delete(path)
  }

  func fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance] {
    let path = "accounts/\(accountId.apiString)/balances"
    let data = try await client.get(path)
    let dtos = try JSONDecoder().decode([AccountDailyBalanceDTO].self, from: data)
    return dtos.map { $0.toDomain(instrument: instrument) }
  }
}
