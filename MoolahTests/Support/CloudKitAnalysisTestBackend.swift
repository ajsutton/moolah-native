import Foundation
import GRDB
import SwiftData

@testable import Moolah

// A BackendProvider that uses CloudKit repositories backed by an in-memory
// SwiftData container. Used by the `AnalysisRepository` contract tests.
//
// Visibility is internal (was fileprivate) so sibling test files across the
// split AnalysisRepository* test suites can use this helper — `strict_fileprivate`
// disallows fileprivate in this codebase.
struct CloudKitAnalysisTestBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let investments: any InvestmentRepository
  let conversionService: any InstrumentConversionService
  let csvImportProfiles: any CSVImportProfileRepository
  let importRules: any ImportRuleRepository

  /// Creates a backend wired to an in-memory SwiftData container.
  ///
  /// - Parameter customConversion: An optional conversion service override. When
  ///   `nil`, a default `FiatConversionService` backed by a throwaway file-based
  ///   cache is created.
  ///
  /// Throws when the in-memory `ModelContainer` fails to construct.
  init(conversionService customConversion: (any InstrumentConversionService)? = nil) throws {
    let container = try TestModelContainer.create()
    let currency = Instrument.defaultTestInstrument
    let conversion: any InstrumentConversionService
    if let customConversion {
      conversion = customConversion
    } else {
      let rateClient = FixedRateClient()
      let exchangeRates = ExchangeRateService(
        client: rateClient, database: try ProfileDatabase.openInMemory())
      conversion = FiatConversionService(exchangeRates: exchangeRates)
    }
    self.auth = InMemoryAuthProvider()
    self.accounts = CloudKitAccountRepository(
      modelContainer: container)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: container,
      instrument: currency,
      conversionService: conversion)
    self.categories = CloudKitCategoryRepository(
      modelContainer: container)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: container, instrument: currency)
    self.conversionService = conversion
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: container, instrument: currency, conversionService: conversion)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: container, instrument: currency)
    let database = try ProfileDatabase.openInMemory()
    self.csvImportProfiles = GRDBCSVImportProfileRepository(database: database)
    self.importRules = GRDBImportRuleRepository(database: database)
  }
}
