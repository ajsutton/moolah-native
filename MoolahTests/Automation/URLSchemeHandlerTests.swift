import Foundation
import Testing

@testable import Moolah

@Suite("URLSchemeHandler")
struct URLSchemeHandlerTests {

  // MARK: - Parsing

  @Test("parses profile-only URL")
  func parseProfileOnly() throws {
    let url = URL(string: "moolah://Personal")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.profileIdentifier == "Personal")
    #expect(route.destination == nil)
  }

  @Test("parses account route with UUID")
  func parseAccountRoute() throws {
    let id = UUID()
    let url = URL(string: "moolah://Personal/account/\(id.uuidString)")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.profileIdentifier == "Personal")
    #expect(route.destination == .account(id))
  }

  @Test("parses transaction route with UUID")
  func parseTransactionRoute() throws {
    let id = UUID()
    let url = URL(string: "moolah://Personal/transaction/\(id.uuidString)")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.profileIdentifier == "Personal")
    #expect(route.destination == .transaction(id))
  }

  @Test("parses analysis with query params")
  func parseAnalysisWithParams() throws {
    let url = URL(string: "moolah://Personal/analysis?history=12&forecast=3")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.profileIdentifier == "Personal")
    #expect(route.destination == .analysis(history: 12, forecast: 3))
  }

  @Test("parses analysis without query params")
  func parseAnalysisNoParams() throws {
    let url = URL(string: "moolah://Personal/analysis")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.destination == .analysis(history: nil, forecast: nil))
  }

  @Test("parses reports with date range")
  func parseReportsWithDates() throws {
    let url = URL(string: "moolah://Personal/reports?from=2026-01-01&to=2026-03-31")!
    let route = try URLSchemeHandler.parse(url)

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let expectedFrom = formatter.date(from: "2026-01-01")!
    let expectedTo = formatter.date(from: "2026-03-31")!

    #expect(route.destination == .reports(from: expectedFrom, to: expectedTo))
  }

  @Test("parses reports without date range")
  func parseReportsNoDates() throws {
    let url = URL(string: "moolah://Personal/reports")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.destination == .reports(from: nil, to: nil))
  }

  @Test("parses percent-encoded profile name")
  func parseEncodedProfileName() throws {
    let url = URL(string: "moolah://My%20Finances/analysis")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.profileIdentifier == "My Finances")
  }

  @Test(
    "parses simple destinations",
    arguments: [
      ("accounts", URLSchemeHandler.Destination.accounts),
      ("earmarks", URLSchemeHandler.Destination.earmarks),
      ("categories", URLSchemeHandler.Destination.categories),
      ("upcoming", URLSchemeHandler.Destination.upcoming),
    ]
  )
  func parseSimpleDestination(path: String, expected: URLSchemeHandler.Destination) throws {
    let url = URL(string: "moolah://Test/\(path)")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.destination == expected)
  }

  @Test("parses earmark with UUID")
  func parseEarmarkRoute() throws {
    let id = UUID()
    let url = URL(string: "moolah://Test/earmark/\(id.uuidString)")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.destination == .earmark(id))
  }

  @Test("case-insensitive path matching")
  func caseInsensitivePath() throws {
    let url = URL(string: "moolah://Test/Analysis")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.destination == .analysis(history: nil, forecast: nil))
  }

  @Test("case-insensitive UUID matching")
  func caseInsensitiveUUID() throws {
    let id = UUID()
    let url = URL(string: "moolah://Test/account/\(id.uuidString.lowercased())")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.destination == .account(id))
  }

  // MARK: - Error Cases

  @Test("throws for invalid scheme")
  func invalidScheme() throws {
    let url = URL(string: "https://Personal/accounts")!
    #expect(throws: URLSchemeHandler.ParseError.self) {
      try URLSchemeHandler.parse(url)
    }
  }

  @Test("throws for missing profile name")
  func missingProfileName() throws {
    let url = URL(string: "moolah:///accounts")!
    #expect(throws: URLSchemeHandler.ParseError.self) {
      try URLSchemeHandler.parse(url)
    }
  }

  @Test("throws for invalid UUID in account route")
  func invalidUUIDAccount() throws {
    let url = URL(string: "moolah://Test/account/not-a-uuid")!
    #expect(throws: URLSchemeHandler.ParseError.self) {
      try URLSchemeHandler.parse(url)
    }
  }

  @Test("throws for invalid UUID in transaction route")
  func invalidUUIDTransaction() throws {
    let url = URL(string: "moolah://Test/transaction/bad")!
    #expect(throws: URLSchemeHandler.ParseError.self) {
      try URLSchemeHandler.parse(url)
    }
  }

  @Test("throws for invalid UUID in earmark route")
  func invalidUUIDEarmark() throws {
    let url = URL(string: "moolah://Test/earmark/bad")!
    #expect(throws: URLSchemeHandler.ParseError.self) {
      try URLSchemeHandler.parse(url)
    }
  }

  @Test("throws for unknown destination")
  func unknownDestination() throws {
    let url = URL(string: "moolah://Test/unknown")!
    #expect(throws: URLSchemeHandler.ParseError.self) {
      try URLSchemeHandler.parse(url)
    }
  }

  // MARK: - toSidebarSelection

  @Test("maps account to sidebar selection")
  func sidebarAccount() {
    let id = UUID()
    #expect(URLSchemeHandler.toSidebarSelection(.account(id)) == .account(id))
  }

  @Test("maps earmark to sidebar selection")
  func sidebarEarmark() {
    let id = UUID()
    #expect(URLSchemeHandler.toSidebarSelection(.earmark(id)) == .earmark(id))
  }

  @Test("maps analysis to sidebar selection")
  func sidebarAnalysis() {
    #expect(
      URLSchemeHandler.toSidebarSelection(.analysis(history: nil, forecast: nil)) == .analysis)
  }

  @Test("maps reports to sidebar selection")
  func sidebarReports() {
    #expect(URLSchemeHandler.toSidebarSelection(.reports(from: nil, to: nil)) == .reports)
  }

  @Test("maps categories to sidebar selection")
  func sidebarCategories() {
    #expect(URLSchemeHandler.toSidebarSelection(.categories) == .categories)
  }

  @Test("maps upcoming to sidebar selection")
  func sidebarUpcoming() {
    #expect(URLSchemeHandler.toSidebarSelection(.upcoming) == .upcomingTransactions)
  }

  @Test("maps accounts to nil (handled differently)")
  func sidebarAccounts() {
    #expect(URLSchemeHandler.toSidebarSelection(.accounts) == nil)
  }

  @Test("maps earmarks to nil (handled differently)")
  func sidebarEarmarks() {
    #expect(URLSchemeHandler.toSidebarSelection(.earmarks) == nil)
  }

  @Test("maps transaction to nil (handled differently)")
  func sidebarTransaction() {
    let id = UUID()
    #expect(URLSchemeHandler.toSidebarSelection(.transaction(id)) == nil)
  }
}
