struct Currency: Codable, Sendable, Hashable {
  public static let AUD: Currency = .init(code: "AUD", symbol: "$", decimals: 2)
  public static let USD: Currency = .init(code: "USD", symbol: "$", decimals: 2)

  let code: String
  let symbol: String
  let decimals: Int
}
