import Foundation
import SwiftData

/// Deletes all CloudKit-synced data for a specific profile.
/// Used when removing an iCloud profile to clean up its associated records.
struct ProfileDataDeleter {
  let modelContext: ModelContext

  @MainActor
  func deleteAllData(for profileId: UUID) {
    deleteTransactions(profileId: profileId)
    deleteAccounts(profileId: profileId)
    deleteCategories(profileId: profileId)
    deleteEarmarks(profileId: profileId)
    deleteEarmarkBudgetItems(profileId: profileId)
    deleteInvestmentValues(profileId: profileId)
    deleteProfileRecord(profileId: profileId)
    try? modelContext.save()
  }

  @MainActor
  private func deleteTransactions(profileId: UUID) {
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor
  private func deleteAccounts(profileId: UUID) {
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor
  private func deleteCategories(profileId: UUID) {
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor
  private func deleteEarmarks(profileId: UUID) {
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor
  private func deleteEarmarkBudgetItems(profileId: UUID) {
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor
  private func deleteInvestmentValues(profileId: UUID) {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor
  private func deleteProfileRecord(profileId: UUID) {
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }
}
