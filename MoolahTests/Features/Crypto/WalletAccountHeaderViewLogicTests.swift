// MoolahTests/Features/Crypto/WalletAccountHeaderViewLogicTests.swift
import Foundation
import Testing

@testable import Moolah

/// Pure-logic tests for `WalletAccountHeaderLogic` — the relative-time
/// formatting for the last-synced label, the "is sync allowed" predicate,
/// and the user-facing error caption. These are the load-bearing pieces
/// of the wallet-header view; the SwiftUI rendering itself is exercised
/// via preview snapshots and the UI driver suite.
@Suite("WalletAccountHeaderLogic")
struct WalletAccountHeaderViewLogicTests {
  // MARK: - Last-synced text

  @Test("Nil sync state renders as 'Never synced'")
  func neverSyncedWhenStateAbsent() {
    let label = WalletAccountHeaderLogic.lastSyncedText(state: nil, now: Date())
    #expect(label == "Never synced")
  }

  @Test("Recent sync renders with the 'Synced ' prefix")
  func recentSyncIsPrefixedWithSynced() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let oneMinuteAgo = now.addingTimeInterval(-60)
    let state = WalletSyncState(
      id: UUID(), lastSyncedBlockNumber: 0, lastSyncedAt: oneMinuteAgo, lastError: nil)
    let label = WalletAccountHeaderLogic.lastSyncedText(state: state, now: now)
    #expect(label.hasPrefix("Synced "))
    // The locale-specific RelativeDateTimeFormatter output isn't a stable
    // assertion target across CI environments — we pin only the prefix
    // and that the label is non-empty after the space.
    #expect(label.count > "Synced ".count)
  }

  @Test("Two-hour-old sync uses a non-empty relative description")
  func twoHourOldSyncHasNonEmptyDescription() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let twoHoursAgo = now.addingTimeInterval(-7_200)
    let state = WalletSyncState(
      id: UUID(), lastSyncedBlockNumber: 1_234, lastSyncedAt: twoHoursAgo, lastError: nil)
    let label = WalletAccountHeaderLogic.lastSyncedText(state: state, now: now)
    #expect(label.hasPrefix("Synced "))
    let trailing = label.dropFirst("Synced ".count)
    #expect(!trailing.isEmpty)
  }

  // MARK: - Sync-now enabled state

  @Test("Sync-now button enabled when account is not in flight and a key is configured")
  func syncEnabledWhenNotInFlight() {
    let id = UUID()
    #expect(
      WalletAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [], hasApiKey: true))
    #expect(
      WalletAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [UUID()], hasApiKey: true))
  }

  @Test("Sync-now button disabled while account is in flight")
  func syncDisabledWhenInFlight() {
    let id = UUID()
    #expect(
      !WalletAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [id], hasApiKey: true))
  }

  @Test("Sync-now button disabled when no Alchemy key is configured")
  func syncDisabledWhenNoApiKey() {
    let id = UUID()
    // Even idle and otherwise eligible, no key → no sync.
    #expect(
      !WalletAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [], hasApiKey: false))
    // And in-flight + no key still resolves to disabled.
    #expect(
      !WalletAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [id], hasApiKey: false))
  }

  // MARK: - Inline error caption

  @Test("Nil lastError yields no inline error caption")
  func errorCaptionAbsentWhenNoError() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 100,
      lastSyncedAt: now.addingTimeInterval(-60),
      lastError: nil)
    #expect(WalletAccountHeaderLogic.errorCaption(for: state) == nil)
    #expect(WalletAccountHeaderLogic.errorCaption(for: nil) == nil)
  }

  @Test(".invalidApiKey produces a non-empty user-facing caption")
  func invalidApiKeyProducesCaption() {
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 0,
      lastSyncedAt: .distantPast,
      lastError: .invalidApiKey)
    let caption = WalletAccountHeaderLogic.errorCaption(for: state)
    #expect(caption != nil)
    #expect(caption?.isEmpty == false)
  }

  @Test(".missingApiKey produces a non-empty user-facing caption")
  func missingApiKeyProducesCaption() {
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 0,
      lastSyncedAt: .distantPast,
      lastError: .missingApiKey)
    let caption = WalletAccountHeaderLogic.errorCaption(for: state)
    #expect(caption != nil)
    #expect(caption?.isEmpty == false)
  }
}
