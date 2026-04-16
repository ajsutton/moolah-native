import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "URLScheme")

enum URLSchemeHandler {
  struct Route: Sendable {
    let profileIdentifier: String
    let destination: Destination?
  }

  enum Destination: Sendable, Equatable {
    case accounts
    case account(UUID)
    case transaction(UUID)
    case earmarks
    case earmark(UUID)
    case analysis(history: Int?, forecast: Int?)
    case reports(from: Date?, to: Date?)
    case categories
    case upcoming
  }

  enum ParseError: LocalizedError, Sendable {
    case invalidScheme(String)
    case missingProfileName
    case invalidUUID(String)
    case unknownDestination(String)

    var errorDescription: String? {
      switch self {
      case .invalidScheme(let scheme): "Invalid URL scheme: '\(scheme)' (expected 'moolah')"
      case .missingProfileName: "URL must include a profile name as the host"
      case .invalidUUID(let value): "Invalid UUID: '\(value)'"
      case .unknownDestination(let path): "Unknown destination: '\(path)'"
      }
    }
  }

  static func parse(_ url: URL) throws -> Route {
    guard url.scheme?.lowercased() == "moolah" else {
      throw ParseError.invalidScheme(url.scheme ?? "<none>")
    }

    guard let profileIdentifier = url.host(percentEncoded: false), !profileIdentifier.isEmpty else {
      throw ParseError.missingProfileName
    }

    // Extract path components (dropping the leading "/" empty component)
    let pathComponents = url.pathComponents.filter { $0 != "/" }

    guard let firstComponent = pathComponents.first else {
      return Route(profileIdentifier: profileIdentifier, destination: nil)
    }

    let destination = try parseDestination(
      firstComponent.lowercased(),
      pathComponents: pathComponents,
      queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    )

    return Route(profileIdentifier: profileIdentifier, destination: destination)
  }

  private static func parseDestination(
    _ name: String,
    pathComponents: [String],
    queryItems: [URLQueryItem]?
  ) throws -> Destination {
    switch name {
    case "accounts":
      return .accounts
    case "account":
      let id = try requireUUID(from: pathComponents, at: 1)
      return .account(id)
    case "transaction":
      let id = try requireUUID(from: pathComponents, at: 1)
      return .transaction(id)
    case "earmarks":
      return .earmarks
    case "earmark":
      let id = try requireUUID(from: pathComponents, at: 1)
      return .earmark(id)
    case "analysis":
      let history = queryItems?.first(where: { $0.name == "history" })?.value.flatMap(Int.init)
      let forecast = queryItems?.first(where: { $0.name == "forecast" })?.value.flatMap(Int.init)
      return .analysis(history: history, forecast: forecast)
    case "reports":
      let dateFormatter = ISO8601DateFormatter()
      dateFormatter.formatOptions = [.withFullDate]
      let from = queryItems?.first(where: { $0.name == "from" })?.value.flatMap(
        dateFormatter.date(from:))
      let to = queryItems?.first(where: { $0.name == "to" })?.value.flatMap(
        dateFormatter.date(from:))
      return .reports(from: from, to: to)
    case "categories":
      return .categories
    case "upcoming":
      return .upcoming
    default:
      throw ParseError.unknownDestination(name)
    }
  }

  private static func requireUUID(from components: [String], at index: Int) throws -> UUID {
    guard index < components.count else {
      throw ParseError.invalidUUID("<missing>")
    }
    guard let uuid = UUID(uuidString: components[index]) else {
      throw ParseError.invalidUUID(components[index])
    }
    return uuid
  }

  // MARK: - Sidebar Mapping

  static func toSidebarSelection(_ destination: Destination) -> SidebarSelection? {
    switch destination {
    case .account(let id):
      return .account(id)
    case .earmark(let id):
      return .earmark(id)
    case .analysis:
      return .analysis
    case .reports:
      return .reports
    case .categories:
      return .categories
    case .upcoming:
      return .upcomingTransactions
    case .accounts, .earmarks, .transaction:
      return nil
    }
  }
}
