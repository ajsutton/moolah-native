import Foundation
import GRDB

@testable import Moolah

/// Shared helpers for the split AccountStore test suites. Extracted from the
/// original monolithic `AccountStoreTests.swift` so the focused suites
/// (`AccountStoreLoadingTests`, `AccountStoreApplyDeltaTests`, etc.) can share
/// fixtures without duplicating private helpers across files.
@MainActor
enum AccountStoreTestSupport {
  static func seedAccount(
    id: UUID = UUID(),
    name: String,
    type: AccountType = .bank,
    instrument: Instrument = .defaultTestInstrument,
    balance: Decimal = 0,
    position: Int = 0,
    isHidden: Bool = false,
    valuationMode: ValuationMode = .recordedValue,
    in database: any DatabaseWriter
  ) -> Account {
    let account = Account(
      id: id, name: name, type: type, instrument: instrument, position: position,
      isHidden: isHidden, valuationMode: valuationMode)
    let balanceAmount = InstrumentAmount(quantity: balance, instrument: instrument)
    TestBackend.seed(
      accounts: [(account: account, openingBalance: balanceAmount)],
      in: database,
      instrument: instrument)
    return account
  }
}

/// In-memory AccountRepository whose methods can be toggled to fail, letting
/// tests exercise error-handling paths without spinning up CloudKit.
final class FailingAccountRepository: AccountRepository, @unchecked Sendable {
  private var accounts: [Account]
  var shouldFail = false
  var failOnUpdate = false

  init(accounts: [Account]) {
    self.accounts = accounts
  }

  func fetchAll() async throws -> [Account] {
    if shouldFail { throw BackendError.networkUnavailable }
    return accounts
  }

  func create(_ account: Account, openingBalance: InstrumentAmount?) async throws -> Account {
    if shouldFail { throw BackendError.networkUnavailable }
    accounts.append(account)
    return account
  }

  func update(_ account: Account) async throws -> Account {
    if shouldFail || failOnUpdate { throw BackendError.networkUnavailable }
    if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
      accounts[idx] = account
    }
    return account
  }

  func delete(id: UUID) async throws {
    if shouldFail { throw BackendError.networkUnavailable }
    accounts.removeAll { $0.id == id }
  }
}
