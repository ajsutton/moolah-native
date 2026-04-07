struct Currency: Codable, Sendable, Hashable {
  public static let AUD: Currency = .init(code: "AUD", decimals: 2)
  public static let USD: Currency = .init(code: "USD", decimals: 2)
  public static let defaultCurrency: Currency = AUD

  let code: String
  let decimals: Int
}
