import Foundation
import Testing

@testable import Moolah

/// Regression guard for the App Intents `AccountTypeEnum` mirror of the
/// domain `AccountType`. Adding a case to `AccountType` without adding
/// the matching `AccountTypeEnum` case (and display representation) is
/// silent at compile time — the mirror is a separate enum, so Swift's
/// exhaustiveness check doesn't catch the gap. These tests fail loudly
/// when the two drift apart so Siri / Shortcuts users can keep filtering
/// by every supported account type.
@Suite("ListAccountsIntent — AccountTypeEnum mirror")
struct ListAccountsIntentTypeMirrorTests {
  @Test("Every AccountType has a matching AccountTypeEnum case")
  func everyDomainTypeMirrored() {
    for domain in AccountType.allCases {
      let matchingMirror = AccountTypeEnum.allCases.first(where: { $0.toDomainType == domain })
      #expect(
        matchingMirror != nil,
        "AccountType.\(domain) has no matching AccountTypeEnum case — Shortcuts can't filter by it")
    }
  }

  @Test("AccountTypeEnum has a display representation for every case")
  func everyMirrorCaseHasDisplay() {
    for mirror in AccountTypeEnum.allCases {
      #expect(
        AccountTypeEnum.caseDisplayRepresentations[mirror] != nil,
        "AccountTypeEnum.\(mirror) is missing a caseDisplayRepresentation entry")
    }
  }

  @Test("Crypto wallets are exposed via AccountTypeEnum")
  func cryptoExposed() {
    let cryptoMirror = AccountTypeEnum.allCases.first(where: { $0.toDomainType == .crypto })
    #expect(cryptoMirror != nil)
    #expect(AccountTypeEnum.caseDisplayRepresentations[.crypto] != nil)
  }
}
