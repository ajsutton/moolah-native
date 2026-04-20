import Foundation
import SwiftData

@testable import Moolah

/// Creates an in-memory ModelContainer with all CloudKit model types.
/// No CloudKit sync — pure local SwiftData for fast testing.
enum TestModelContainer {
  static func create() throws -> ModelContainer {
    let schema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      TransactionLegRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
      InstrumentRecord.self,
    ])
    // `cloudKitDatabase: .none` is critical: the test binary is signed with
    // iCloud entitlements, so SwiftData's default (`.automatic`) attaches
    // CoreData+CloudKit mirroring to every in-memory store in the process.
    // Mirroring on a /dev/null store fails but can still import records from
    // iCloud into the test container before tearing down — the cause of the
    // `AnalysisRepositoryContractTests` daily-revaluation flake.
    let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return try ModelContainer(for: schema, configurations: [config])
  }
}
