import Foundation
import SwiftData
import os

/// `create`, `update`, `delete`, and `fetchPayeeSuggestions` — separated
/// from the main file so the read-path (`fetch`) and its helpers stay
/// under SwiftLint's body-length thresholds.
extension CloudKitTransactionRepository {
  func create(_ transaction: Transaction) async throws -> Transaction {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.create", signpostID: signpostID)
    }
    let record = TransactionRecord.from(transaction)
    try await MainActor.run {
      context.insert(record)

      var legRecords: [TransactionLegRecord] = []
      for (index, leg) in transaction.legs.enumerated() {
        try ensureInstrument(leg.instrument)
        let legRecord = TransactionLegRecord.from(
          leg, transactionId: transaction.id, sortOrder: index)
        context.insert(legRecord)
        legRecords.append(legRecord)
      }

      try context.save()
      onRecordChanged(transaction.id)
      for legRecord in legRecords {
        onRecordChanged(legRecord.id)
      }
    }
    return transaction
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.update", signpostID: signpostID)
    }
    let txnId = transaction.id
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == txnId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      applyMetadata(of: transaction, to: record)

      let legDescriptor = FetchDescriptor<TransactionLegRecord>(
        predicate: #Predicate { $0.transactionId == txnId }
      )
      let oldLegs = try context.fetch(legDescriptor)
      let oldLegIds = oldLegs.map(\.id)
      for oldLeg in oldLegs {
        context.delete(oldLeg)
      }

      var newLegRecords: [TransactionLegRecord] = []
      for (index, leg) in transaction.legs.enumerated() {
        try ensureInstrument(leg.instrument)
        let legRecord = TransactionLegRecord.from(
          leg, transactionId: transaction.id, sortOrder: index)
        context.insert(legRecord)
        newLegRecords.append(legRecord)
      }

      try context.save()
      onRecordChanged(transaction.id)
      for legRecord in newLegRecords {
        onRecordChanged(legRecord.id)
      }
      for oldLegId in oldLegIds {
        onRecordDeleted(oldLegId)
      }
    }
    return transaction
  }

  func delete(id: UUID) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.delete", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.delete", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == id }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }

      let legDescriptor = FetchDescriptor<TransactionLegRecord>(
        predicate: #Predicate { $0.transactionId == id }
      )
      let legs = try context.fetch(legDescriptor)
      let legIds = legs.map(\.id)
      for leg in legs {
        context.delete(leg)
      }

      context.delete(record)
      try context.save()
      onRecordDeleted(id)
      for legId in legIds {
        onRecordDeleted(legId)
      }
    }
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.fetchPayeeSuggestions",
      signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.fetchPayeeSuggestions",
        signpostID: signpostID)
    }
    guard !prefix.isEmpty else { return [] }
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.payee != nil }
    )

    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      let lowered = prefix.lowercased()
      let matching = records.compactMap(\.payee)
        .filter { !$0.isEmpty && $0.lowercased().hasPrefix(lowered) }

      var counts: [String: Int] = [:]
      for payee in matching {
        counts[payee, default: 0] += 1
      }
      return counts.sorted { $0.value > $1.value }.map(\.key)
    }
  }

  @MainActor
  private func applyMetadata(of transaction: Transaction, to record: TransactionRecord) {
    record.date = transaction.date
    record.payee = transaction.payee
    record.notes = transaction.notes
    record.recurPeriod = transaction.recurPeriod?.rawValue
    record.recurEvery = transaction.recurEvery
    record.importOrigin = transaction.importOrigin
  }
}
