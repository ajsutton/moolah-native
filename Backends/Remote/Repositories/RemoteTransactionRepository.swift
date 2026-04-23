// swiftlint:disable multiline_arguments

import Foundation
import OSLog

final class RemoteTransactionRepository: TransactionRepository, Sendable {
  private let client: APIClient
  private let instrument: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteTransactionRepository")

  init(client: APIClient, instrument: Instrument) {
    self.client = client
    self.instrument = instrument
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    var queryItems: [URLQueryItem] = []

    queryItems.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
    queryItems.append(URLQueryItem(name: "offset", value: String(page * pageSize)))

    if let accountId = filter.accountId {
      queryItems.append(URLQueryItem(name: "account", value: accountId.apiString))
    }

    if let earmarkId = filter.earmarkId {
      queryItems.append(URLQueryItem(name: "earmark", value: earmarkId.apiString))
    }

    if let scheduled = filter.scheduled {
      queryItems.append(URLQueryItem(name: "scheduled", value: String(scheduled)))
    }

    if let dateRange = filter.dateRange {
      queryItems.append(
        URLQueryItem(
          name: "from", value: BackendDateFormatter.string(from: dateRange.lowerBound)))
      queryItems.append(
        URLQueryItem(
          name: "to", value: BackendDateFormatter.string(from: dateRange.upperBound)))
    }

    if !filter.categoryIds.isEmpty {
      for categoryId in filter.categoryIds {
        queryItems.append(URLQueryItem(name: "category", value: categoryId.apiString))
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
        transactions: wrapper.transactions.map { $0.toDomain(instrument: self.instrument) },
        targetInstrument: self.instrument,
        priorBalance: InstrumentAmount(
          quantity: Decimal(wrapper.priorBalance) / 100, instrument: self.instrument),
        totalCount: wrapper.totalNumberOfTransactions
      )
    } catch {
      logger.error("Decoding error: \(error.localizedDescription)")
      throw error
    }
  }

  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    var all: [Transaction] = []
    var page = 0
    let pageSize = 500
    while true {
      let result = try await fetch(filter: filter, page: page, pageSize: pageSize)
      try Task.checkCancellation()
      all.append(contentsOf: result.transactions)
      if result.transactions.count < pageSize { break }
      page += 1
    }
    return all
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    try requireAllLegsMatchProfile(transaction)
    let dto = try CreateTransactionDTO.fromDomain(transaction)
    let data = try await client.post("transactions/", body: dto)
    let responseDTO = try JSONDecoder().decode(TransactionDTO.self, from: data)
    return responseDTO.toDomain(instrument: instrument)
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    try requireAllLegsMatchProfile(transaction)
    let dto = try TransactionDTO.fromDomain(transaction)
    let data = try await client.put("transactions/\(transaction.id.apiString)/", body: dto)
    let responseDTO = try JSONDecoder().decode(TransactionDTO.self, from: data)
    return responseDTO.toDomain(instrument: instrument)
  }

  private func requireAllLegsMatchProfile(_ transaction: Transaction) throws {
    for (index, leg) in transaction.legs.enumerated() {
      try requireMatchesProfileInstrument(
        leg.instrument, profile: instrument,
        entity: "Transaction leg \(index + 1)")
    }
  }

  func delete(id: UUID) async throws {
    _ = try await client.delete("transactions/\(id.apiString)/")
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    // The server has no dedicated payee suggestion endpoint.
    // Query transactions filtered by payee substring and extract unique payees.
    var queryItems = [URLQueryItem(name: "payee", value: prefix)]
    queryItems.append(URLQueryItem(name: "pageSize", value: "100"))
    queryItems.append(URLQueryItem(name: "offset", value: "0"))

    let data = try await client.get("transactions/", queryItems: queryItems)
    let wrapper = try JSONDecoder().decode(TransactionDTO.ListWrapper.self, from: data)
    // Count frequency of each payee and sort most-used first
    let matching = wrapper.transactions.compactMap(\.payee).filter { !$0.isEmpty }
    var counts: [String: Int] = [:]
    for payee in matching {
      counts[payee, default: 0] += 1
    }
    return counts.sorted { $0.value > $1.value }.map(\.key)
  }
}
