import Foundation
import Testing

@testable import Moolah

@Suite("ExportedData")
struct ExportedDataTests {

  private let currency = Currency.defaultTestCurrency

  @Test("JSON round-trip preserves all fields")
  func jsonRoundTrip() throws {
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let exportDate = Date(timeIntervalSince1970: 1_700_000_000)

    let original = ExportedData(
      version: 1,
      exportedAt: exportDate,
      profileLabel: "My Profile",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 5000, currency: currency)
        )
      ],
      categories: [
        Category(id: categoryId, name: "Food")
      ],
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday",
          balance: .zero(currency: currency),
          saved: .zero(currency: currency),
          spent: .zero(currency: currency)
        )
      ],
      earmarkBudgets: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: categoryId,
            amount: MonetaryAmount(cents: 1000, currency: currency)
          )
        ]
      ],
      transactions: [
        Transaction(
          type: .income, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: 5000, currency: currency),
          payee: "Employer"
        )
      ],
      investmentValues: [:]
    )

    let data = try JSONEncoder.exportEncoder.encode(original)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)

    #expect(decoded.version == original.version)
    #expect(decoded.exportedAt == original.exportedAt)
    #expect(decoded.profileLabel == original.profileLabel)
    #expect(decoded.currencyCode == original.currencyCode)
    #expect(decoded.financialYearStartMonth == original.financialYearStartMonth)
    #expect(decoded.accounts.count == original.accounts.count)
    #expect(decoded.accounts.first?.id == accountId)
    #expect(decoded.accounts.first?.name == "Checking")
    #expect(decoded.categories.count == original.categories.count)
    #expect(decoded.categories.first?.id == categoryId)
    #expect(decoded.earmarks.count == original.earmarks.count)
    #expect(decoded.earmarks.first?.id == earmarkId)
    #expect(decoded.earmarkBudgets[earmarkId]?.count == 1)
    #expect(decoded.transactions.count == original.transactions.count)
    #expect(decoded.investmentValues.isEmpty)
  }

  @Test("version field is present in JSON output")
  func versionFieldInJSON() throws {
    let exported = ExportedData(
      version: 1,
      exportedAt: Date(),
      profileLabel: "Test",
      currencyCode: "USD",
      financialYearStartMonth: 1,
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )

    let data = try JSONEncoder.exportEncoder.encode(exported)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    #expect(json["version"] as? Int == 1)
    #expect(json["profileLabel"] as? String == "Test")
    #expect(json["currencyCode"] as? String == "USD")
    #expect(json["financialYearStartMonth"] as? Int == 1)
  }

  @Test("default metadata values for backward compatibility")
  func defaultMetadataValues() {
    let exported = ExportedData(
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )

    #expect(exported.version == 1)
    #expect(exported.profileLabel == "")
    #expect(exported.currencyCode == "")
    #expect(exported.financialYearStartMonth == 1)
  }
}
