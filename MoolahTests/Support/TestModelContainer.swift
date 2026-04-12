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
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }
}
