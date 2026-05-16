// MoolahTests/Shared/CryptoImport/CrossAccountTransferMergerTestDoubles.swift
import Foundation

@testable import Moolah

/// Namespace anchor so SwiftLint's `file_name` rule matches this file's name.
enum CrossAccountTransferMergerTestDoubles {}

/// Records every `merge(...)` invocation and delegates to a live merger
/// so the produced output is real. Used by the structural test that
/// asserts the apply pass calls the merger exactly once after the
/// parallel build TaskGroup completes — i.e. with the union of every
/// participating account's candidates, not once-per-account with
/// partial input.
final class RecordingCrossAccountTransferMerger:
  CrossAccountTransferMerger, @unchecked Sendable
{
  struct Invocation: Sendable {
    let candidates: [BuiltTransaction]
  }

  private let lock = NSLock()
  private var invocationsBacking: [Invocation] = []
  private let inner: any CrossAccountTransferMerger

  init(delegateTo inner: any CrossAccountTransferMerger = LiveCrossAccountTransferMerger()) {
    self.inner = inner
  }

  var invocations: [Invocation] {
    lock.withLock { invocationsBacking }
  }

  func merge(
    candidates: [BuiltTransaction],
    existingLegLookup: @Sendable (_ externalId: String) async throws -> [TransactionLeg]
  ) async throws -> [BuiltTransaction] {
    lock.withLock {
      invocationsBacking.append(Invocation(candidates: candidates))
    }
    return try await inner.merge(candidates: candidates, existingLegLookup: existingLegLookup)
  }
}
