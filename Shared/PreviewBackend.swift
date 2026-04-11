import Foundation
import SwiftData

/// Factory for creating CloudKitBackend instances for SwiftUI previews.
/// Uses in-memory SwiftData — no CloudKit sync, fast initialization.
enum PreviewBackend {
  static func create(currency: Currency = .AUD) -> (CloudKitBackend, ModelContainer, UUID) {
    let schema = Schema([
      ProfileRecord.self,
      AccountRecord.self,
      TransactionRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let profileId = UUID()
    let backend = CloudKitBackend(
      modelContainer: container, profileId: profileId,
      currency: currency, profileLabel: "Preview"
    )
    return (backend, container, profileId)
  }
}
