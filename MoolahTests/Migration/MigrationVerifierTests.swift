import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("MigrationVerifier")
@MainActor
struct MigrationVerifierTests {

  private let instrument = Instrument.defaultTestInstrument

  @Test("verification passes when counts and balances match")
  func countsMatch() async throws {
    let container = try TestModelContainer.create()
    let accountId = UUID()

    let exported = ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          instrument: instrument,
          positions: [Position(instrument: instrument, quantity: Decimal(string: "50.00")!)]
        )
      ],
      categories: [Category(name: "Food")],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: instrument,
              quantity: Decimal(string: "50.00")!, type: .income
            )
          ]
        )
      ],
      investmentValues: [:]
    )

    // Import the data
    let importer = CloudKitDataImporter(
      modelContainer: container,
      currencyCode: instrument.id
    )
    _ = try await importer.importData(exported)

    // Verify
    let verifier = MigrationVerifier()
    let result = try await verifier.verify(
      exported: exported,
      modelContainer: container
    )

    #expect(result.countMatch == true)
    #expect(result.balanceMismatches.isEmpty)
    #expect(result.expectedCounts.accounts == 1)
    #expect(result.actualCounts.accounts == 1)
  }

  @Test("verification fails when transaction count mismatches")
  func countMismatch() async throws {
    let container = try TestModelContainer.create()
    let accountId = UUID()

    // Export claims 2 transactions
    let exported = makeCountMismatchExport(accountId: accountId)

    // Import only 1 transaction manually via records
    try insertSingleTransactionRecord(into: container, accountId: accountId)

    let verifier = MigrationVerifier()
    let result = try await verifier.verify(
      exported: exported,
      modelContainer: container
    )

    #expect(result.countMatch == false)
    #expect(result.expectedCounts.transactions == 2)
    #expect(result.actualCounts.transactions == 1)
  }

  private func makeCountMismatchExport(accountId: UUID) -> ExportedData {
    ExportedData(
      accounts: [
        Account(id: accountId, name: "Checking", type: .bank, instrument: instrument)
      ],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: instrument,
              quantity: Decimal(string: "10.00")!, type: .income
            )
          ]
        ),
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: instrument,
              quantity: Decimal(string: "-5.00")!, type: .expense
            )
          ]
        ),
      ],
      investmentValues: [:]
    )
  }

  private func insertSingleTransactionRecord(
    into container: ModelContainer, accountId: UUID
  ) throws {
    let context = ModelContext(container)
    context.insert(AccountRecord(id: accountId, name: "Checking", type: "bank"))
    let txnRecord = TransactionRecord(
      id: UUID(), date: Date(), recurPeriod: nil, recurEvery: nil
    )
    context.insert(txnRecord)
    let legRecord = TransactionLegRecord.from(
      TransactionLeg(
        accountId: accountId, instrument: instrument,
        quantity: Decimal(string: "10.00")!, type: .income
      ),
      transactionId: txnRecord.id,
      sortOrder: 0
    )
    context.insert(legRecord)
    try context.save()
  }

  @Test("balance verification catches mismatches")
  func balanceMismatch() async throws {
    let container = try TestModelContainer.create()
    let accountId = UUID()

    // Account position says 50.00, but transactions sum to 30.00
    let exported = ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          instrument: instrument,
          positions: [Position(instrument: instrument, quantity: Decimal(string: "50.00")!)]
        )
      ],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: instrument,
              quantity: Decimal(string: "30.00")!, type: .income
            )
          ]
        )
      ],
      investmentValues: [:]
    )

    let importer = CloudKitDataImporter(
      modelContainer: container,
      currencyCode: instrument.id
    )
    _ = try await importer.importData(exported)

    let verifier = MigrationVerifier()
    let result = try await verifier.verify(
      exported: exported,
      modelContainer: container
    )

    // Counts match (1 account, 1 transaction) but balances don't
    #expect(result.countMatch == true)
    #expect(result.balanceMismatches.count == 1)
    #expect(result.balanceMismatches.first?.accountName == "Checking")
    #expect(result.balanceMismatches.first?.serverBalance == 5000)
    #expect(result.balanceMismatches.first?.localBalance == 3000)
  }

  @Test("scheduled transactions excluded from balance computation")
  func scheduledExcludedFromBalance() async throws {
    let container = try TestModelContainer.create()
    let accountId = UUID()

    let exported = ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          instrument: instrument,
          positions: [Position(instrument: instrument, quantity: Decimal(string: "50.00")!)]
        )
      ],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: instrument,
              quantity: Decimal(string: "50.00")!, type: .income
            )
          ]
        ),
        // Scheduled transaction should not affect balance
        Transaction(
          date: Date(),
          recurPeriod: .month,
          recurEvery: 1,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: instrument,
              quantity: Decimal(string: "-10.00")!, type: .expense
            )
          ]
        ),
      ],
      investmentValues: [:]
    )

    let importer = CloudKitDataImporter(
      modelContainer: container,
      currencyCode: instrument.id
    )
    _ = try await importer.importData(exported)

    let verifier = MigrationVerifier()
    let result = try await verifier.verify(
      exported: exported,
      modelContainer: container
    )

    // Balance should match since scheduled txns are excluded
    #expect(result.countMatch == true)
    #expect(result.balanceMismatches.isEmpty)
  }
}
