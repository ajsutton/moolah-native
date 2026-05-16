import Foundation
import Testing

@testable import Moolah

@Suite("CoinstashClient")
struct CoinstashClientTests {
  @Test
  func fetchesAllPagesAndReturnsTransactions() async throws {
    let profile = #"{"data":{"userProfile":{"userId":"u1"}}}"#
    let accounts =
      #"{"data":{"getUserAccounts":{"accounts":[{"accountId":"a1","accountType":"TRADING"}]}}}"#
    let page =
      #"{"data":{"accountTransactions":{"isSuccessful":true,"totalRecordsFound":1,"result":[{"transactionId":"t1","transactedOn":"2026-03-01T05:38:19.186Z","category":"DEPOSIT","type":"CREDIT","assetSymbol":null,"amount":100.0,"amountType":"FIAT","quoteBuyPrice":null,"quoteSellPrice":null,"orderId":null,"orderType":null,"transactionStatus":"COMPLETED"}]}}}"#
    let collector = BodyCollector()
    let client = CoinstashClient(transport: { request in
      let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
      await collector.append(body)
      let json: String
      if body.contains("userProfile") {
        json = profile
      } else if body.contains("getUserAccounts") {
        json = accounts
      } else {
        json = page
      }
      // swiftlint:disable force_unwrapping
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200,
        httpVersion: nil, headerFields: nil)!
      // swiftlint:enable force_unwrapping
      return (Data(json.utf8), response)
    })
    let txns = try await client.fetchTransactions(token: "TOK")
    #expect(txns.count == 1)
    #expect(txns[0].externalId == "t1")
    #expect(await collector.count == 3)
  }

  @Test
  func mapsUnauthorizedToError() async throws {
    let client = CoinstashClient(transport: { request in
      // swiftlint:disable force_unwrapping
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200,
        httpVersion: nil, headerFields: nil)!
      // swiftlint:enable force_unwrapping
      return (Data(#"{"errors":[{"message":"Unauthorized"}]}"#.utf8), response)
    })
    await #expect(throws: ExchangeClientError.self) {
      _ = try await client.fetchTransactions(token: "BAD")
    }
  }
}

private actor BodyCollector {
  private(set) var bodies: [String] = []

  var count: Int { bodies.count }

  func append(_ body: String) { bodies.append(body) }
}
