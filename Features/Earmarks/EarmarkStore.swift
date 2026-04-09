import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class EarmarkStore {
  private(set) var earmarks: Earmarks = Earmarks(from: [])
  private(set) var isLoading = false
  private(set) var error: Error?

  private let repository: EarmarkRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")

  init(repository: EarmarkRepository) {
    self.repository = repository
  }

  func load() async {
    guard !isLoading else { return }

    logger.debug("Loading earmarks...")
    isLoading = true
    error = nil

    do {
      earmarks = Earmarks(from: try await repository.fetchAll())
      logger.debug("Loaded \(self.earmarks.count) earmarks")
    } catch {
      logger.error("Failed to load earmarks: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }

  var visibleEarmarks: [Earmark] {
    earmarks.filter { !$0.isHidden }
  }

  var totalBalance: MonetaryAmount {
    visibleEarmarks.reduce(.zero) { $0 + $1.balance }
  }

  /// Adjusts earmark balances locally based on a transaction change.
  /// - Parameters:
  ///   - old: The previous transaction (nil for creates).
  ///   - new: The new transaction (nil for deletes).
  func applyTransactionDelta(old: Transaction?, new: Transaction?) {
    var updated = earmarks.ordered

    // Remove the old transaction's effect
    if let old, let earmarkId = old.earmarkId {
      // Reverse the effect: remove from balance and reverse saved/spent
      updated = updated.map { earmark in
        guard earmark.id == earmarkId else { return earmark }
        var copy = earmark
        copy.balance = copy.balance - old.amount
        if old.amount.cents > 0 {
          // Was income, decrease saved
          copy.saved = copy.saved - old.amount
        } else {
          // Was expense, decrease spent
          let absAmount = MonetaryAmount(
            cents: abs(old.amount.cents), currency: old.amount.currency)
          copy.spent = copy.spent - absAmount
        }
        return copy
      }
    }

    // Apply the new transaction's effect
    if let new, let earmarkId = new.earmarkId {
      updated = updated.map { earmark in
        guard earmark.id == earmarkId else { return earmark }
        var copy = earmark
        copy.balance = copy.balance + new.amount
        if new.amount.cents > 0 {
          // Is income, increase saved
          copy.saved = copy.saved + new.amount
        } else {
          // Is expense, increase spent
          let absAmount = MonetaryAmount(
            cents: abs(new.amount.cents), currency: new.amount.currency)
          copy.spent = copy.spent + absAmount
        }
        return copy
      }
    }

    earmarks = Earmarks(from: updated)
  }

  func reorderEarmarks(from source: IndexSet, to destination: Int) async {
    var visible = visibleEarmarks
    visible.move(fromOffsets: source, toOffset: destination)

    for index in visible.indices {
      visible[index].position = index
      _ = try? await repository.update(visible[index])
    }

    let hiddenEarmarks = earmarks.ordered.filter { $0.isHidden }
    earmarks = Earmarks(from: visible + hiddenEarmarks)
  }

  func create(_ earmark: Earmark) async -> Earmark? {
    logger.debug("Creating earmark: \(earmark.name)")
    error = nil

    do {
      let created = try await repository.create(earmark)
      // Add the created earmark to local state instead of reloading
      var updated = earmarks.ordered
      updated.append(created)
      earmarks = Earmarks(from: updated)
      logger.debug("Added earmark to local state: \(created.name)")
      return created
    } catch {
      logger.error("Failed to create earmark: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }

  func update(_ earmark: Earmark) async -> Earmark? {
    logger.debug("Updating earmark: \(earmark.name)")
    error = nil

    do {
      let updated = try await repository.update(earmark)
      // Update the earmark in local state instead of reloading
      let updatedList = earmarks.ordered.map { existing in
        existing.id == updated.id ? updated : existing
      }
      earmarks = Earmarks(from: updatedList)
      logger.debug("Updated earmark in local state: \(updated.name)")
      return updated
    } catch {
      logger.error("Failed to update earmark: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }
}
