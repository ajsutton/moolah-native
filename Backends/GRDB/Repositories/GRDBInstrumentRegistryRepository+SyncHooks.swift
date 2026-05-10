// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+SyncHooks.swift

import Foundation
import os

/// Sync-hook plumbing for `GRDBInstrumentRegistryRepository`.
///
/// Extracted from the main file so it stays under SwiftLint's
/// `file_length` and `type_body_length` thresholds. The shared
/// instrument registry is constructed at app boot before
/// `SyncCoordinator` exists; the coordinator rotates real hooks in
/// via `attachSyncHooks` once both objects are available. Mirrors
/// the lock-guarded `HookState` shape used by
/// `GRDBProfileIndexRepository`.
extension GRDBInstrumentRegistryRepository {
  /// Replaces both hook closures atomically. Called by the
  /// `SyncCoordinator` once it exists; before that the repo is using
  /// the no-op closures from `init`.
  func attachSyncHooks(
    onRecordChanged: @escaping @Sendable (String) -> Void,
    onRecordDeleted: @escaping @Sendable (String) -> Void
  ) {
    hooks.withLock { state in
      state.onRecordChanged = onRecordChanged
      state.onRecordDeleted = onRecordDeleted
    }
  }

  /// Captures `onRecordChanged` under the lock, releases the lock,
  /// then invokes the captured closure. Non-reentrant lock semantics
  /// mean the client closure must never re-enter the repo while the
  /// lock is held, so the read-then-call pattern is required.
  func fireOnRecordChanged(_ id: String) {
    let notify = hooks.withLock { $0.onRecordChanged }
    notify(id)
  }

  /// Captures `onRecordDeleted` under the lock, releases the lock,
  /// then invokes the captured closure. Same non-reentrancy rationale
  /// as `fireOnRecordChanged`.
  func fireOnRecordDeleted(_ id: String) {
    let notify = hooks.withLock { $0.onRecordDeleted }
    notify(id)
  }
}
