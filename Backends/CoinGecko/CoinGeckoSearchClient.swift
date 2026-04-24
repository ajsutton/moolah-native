// Backends/CoinGecko/CoinGeckoSearchClient.swift
import Foundation

struct CoinGeckoSearchClient: CryptoSearchClient {
  private let apiKey: String?
  private let session: URLSession
  private static let baseURL =
    URL(string: "https://api.coingecko.com/api/v3") ?? URL(fileURLWithPath: "/")

  init(apiKey: String? = nil, session: URLSession = .shared) {
    self.apiKey = apiKey
    self.session = session
  }

  func search(query: String) async throws -> [CryptoSearchHit] {
    var components = URLComponents(
      url: Self.baseURL.appendingPathComponent("search"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "query", value: query)]
    guard let url = components?.url else {
      throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    if let apiKey {
      request.setValue(apiKey, forHTTPHeaderField: "x-cg-demo-api-key")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(CoinGeckoSearchResponse.self, from: data)
    return decoded.coins.map { coin in
      CryptoSearchHit(
        coingeckoId: coin.id,
        symbol: coin.symbol.uppercased(),
        name: coin.name,
        thumbnail: URL(string: coin.thumb ?? "")
      )
    }
  }
}

private struct CoinGeckoSearchResponse: Decodable {
  let coins: [CoinGeckoSearchCoin]
}

private struct CoinGeckoSearchCoin: Decodable {
  let id: String
  let name: String
  let symbol: String
  let thumb: String?
}
