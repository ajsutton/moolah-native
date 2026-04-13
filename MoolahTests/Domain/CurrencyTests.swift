import XCTest

@testable import Moolah

final class CurrencyTests: XCTestCase {
  func testFromCode_AUD() {
    let currency = Currency.from(code: "AUD")
    XCTAssertEqual(currency.code, "AUD")
    XCTAssertEqual(currency.decimals, 2)
    XCTAssertFalse(currency.symbol.isEmpty)
  }

  func testFromCode_USD() {
    let currency = Currency.from(code: "USD")
    XCTAssertEqual(currency.code, "USD")
    XCTAssertEqual(currency.decimals, 2)
  }

  func testFromCode_JPY() {
    let currency = Currency.from(code: "JPY")
    XCTAssertEqual(currency.code, "JPY")
    XCTAssertEqual(currency.decimals, 0)
  }

  func testFromCode_unknownCode() {
    let currency = Currency.from(code: "BTC")
    XCTAssertEqual(currency.code, "BTC")
    XCTAssertFalse(currency.symbol.isEmpty)
  }

  func testFromCode_emptyCode() {
    let currency = Currency.from(code: "")
    XCTAssertEqual(currency.code, "")
  }

  func testFromCode_sameCodeReturnsSameResult() {
    let a = Currency.from(code: "AUD")
    let b = Currency.from(code: "AUD")
    XCTAssertEqual(a, b)
  }

  func testFromCode_differentCodes() {
    let aud = Currency.from(code: "AUD")
    let usd = Currency.from(code: "USD")
    XCTAssertNotEqual(aud.code, usd.code)
  }
}
