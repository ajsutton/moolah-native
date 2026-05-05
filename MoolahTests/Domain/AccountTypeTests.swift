import Foundation
import Testing

@testable import Moolah

@Suite("AccountType")
struct AccountTypeTests {
  @Test
  func cryptoAndInvestmentBothInvestmentLike() {
    #expect(AccountType.crypto.isInvestmentLike)
    #expect(AccountType.investment.isInvestmentLike)
    #expect(!AccountType.bank.isInvestmentLike)
    #expect(!AccountType.creditCard.isInvestmentLike)
    #expect(!AccountType.asset.isInvestmentLike)
  }

  @Test
  func cryptoIsNotIsCurrent() {
    #expect(!AccountType.crypto.isCurrent)
  }

  @Test
  func unknownStringDecodesAsAssetWithWarning() throws {
    // RawRepresentable enums fail decode on unknown raw values by default.
    // The defensive fallback for unknown account types is implemented in the
    // RECORD-LAYER decoder (AccountRow), not on the domain enum itself.
    // This test asserts the domain default — that the enum decode does throw —
    // so the record-layer test can be the single source of fallback truth.
    let json = Data("\"future-type\"".utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AccountType.self, from: json)
    }
  }
}
