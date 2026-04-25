import Foundation
import Testing

@testable import Moolah

@Suite("SyncProgressFooter labels")
@MainActor
struct SyncProgressFooterTests {

  @Test
  func upToDateLabelMatchesPhase() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .upToDate,
      recordsReceivedThisSession: 0,
      pendingUploads: 0,
      lastSettledAt: Date(timeIntervalSince1970: 0)
    )
    #expect(viewModel.title == "Up to date")
    #expect(viewModel.iconName == "checkmark.icloud")
  }

  @Test
  func receivingLabelIncludesCount() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .receiving,
      recordsReceivedThisSession: 1234,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "Receiving from iCloud")
  }

  @Test
  func receivingDetailIncludesCount() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .receiving,
      recordsReceivedThisSession: 1234,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.detail == "1,234 records")
  }

  @Test
  func sendingLabelIncludesCount() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .sending,
      recordsReceivedThisSession: 0,
      pendingUploads: 12,
      lastSettledAt: nil
    )
    #expect(viewModel.detail == "12 changes")
  }

  @Test
  func syncingLabelCombinesCounts() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .syncing,
      recordsReceivedThisSession: 1234,
      pendingUploads: 47,
      lastSettledAt: nil
    )
    #expect(viewModel.detail == "1,234 received · 47 to send")
  }

  @Test
  func degradedQuotaLabel() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .degraded(.quotaExceeded),
      recordsReceivedThisSession: 0,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "iCloud storage full")
  }

  @Test
  func degradedICloudUnavailableLabel() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .degraded(.iCloudUnavailable(.notSignedIn)),
      recordsReceivedThisSession: 0,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "iCloud unavailable")
  }

  @Test
  func degradedRetryingLabel() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .degraded(.retrying),
      recordsReceivedThisSession: 0,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "Retrying")
  }
}
