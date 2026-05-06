// MoolahTests/Features/Crypto/CryptoAccountCreationLogicTests.swift
import Foundation
import Testing

@testable import Moolah

/// Pure-logic tests for `Account.validatedWalletAddress` — the
/// trim/lowercase/regex contract powering the wallet-address field in
/// `CryptoAccountCreationView`. The store-side flow (account creation
/// + sync kick-off) lives in `CryptoAccountCreationStoreTests`.
@Suite("Account.validatedWalletAddress")
struct CryptoAccountCreationLogicTests {
  // 40 hex characters following the `0x` prefix; matches the canonical
  // form. Reused across happy-path tests so the assertion stays anchored
  // on what's being validated rather than on a magic literal.
  private static let canonicalLowercase = "0x" + String(repeating: "a", count: 40)

  @Test("Canonical lowercase form passes through unchanged")
  func canonicalLowercaseAddressIsAccepted() {
    #expect(Account.validatedWalletAddress(Self.canonicalLowercase) == Self.canonicalLowercase)
  }

  @Test("Mixed-case checksum input is normalised to lowercase")
  func mixedCaseChecksumIsLowercased() {
    let mixedCase = "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01"
    let result = Account.validatedWalletAddress(mixedCase)
    #expect(result == mixedCase.lowercased())
  }

  @Test("Surrounding whitespace is trimmed before validation")
  func surroundingWhitespaceIsTrimmed() {
    let padded = "   \(Self.canonicalLowercase)\n"
    #expect(Account.validatedWalletAddress(padded) == Self.canonicalLowercase)
  }

  @Test("Too-short address is rejected")
  func tooShortAddressIsRejected() {
    #expect(Account.validatedWalletAddress("0x123") == nil)
  }

  @Test("ENS-style name is rejected")
  func ensNameIsRejected() {
    #expect(Account.validatedWalletAddress("vitalik.eth") == nil)
  }

  @Test("Empty string is rejected")
  func emptyStringIsRejected() {
    #expect(Account.validatedWalletAddress("") == nil)
  }

  @Test("42-character input without 0x prefix is rejected")
  func missingPrefixIsRejected() {
    let noPrefix = String(repeating: "a", count: 42)
    #expect(Account.validatedWalletAddress(noPrefix) == nil)
  }

  @Test("Non-hex characters in the address are rejected")
  func nonHexCharactersAreRejected() {
    // Replace one digit with `g`, which is outside [0-9a-f].
    let invalid = "0x" + String(repeating: "a", count: 39) + "g"
    #expect(Account.validatedWalletAddress(invalid) == nil)
  }

  @Test("ENS-style hint surfaces for non-0x input containing a dot")
  func ensInputProducesInlineHint() {
    let hint = CryptoAccountCreationView.inlineAddressHint(for: "vitalik.eth")
    #expect(hint != nil)
  }

  @Test("Inline hint is suppressed when the user has typed a 0x prefix")
  func zeroXInputSuppressesInlineHint() {
    #expect(CryptoAccountCreationView.inlineAddressHint(for: "0xabc") == nil)
  }

  @Test("Inline hint is suppressed for empty input")
  func emptyInputProducesNoHint() {
    #expect(CryptoAccountCreationView.inlineAddressHint(for: "") == nil)
  }
}
