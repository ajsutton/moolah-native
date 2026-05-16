import Foundation
import Testing

@testable import Moolah

@Suite("CoinstashGraphQL")
struct CoinstashGraphQLTests {
  @Test
  func decodesTransactionsPage() throws {
    let json = """
      {"data":{"accountTransactions":{"isSuccessful":true,
        "totalRecordsFound":2,"result":[
        {"transactionId":"t1","transactedOn":"2026-03-01T05:38:19.186Z",
         "category":"TRADE","type":"CREDIT","assetSymbol":"OP",
         "amount":3518.46,"amountType":"FIAT","orderId":"o1",
         "orderType":"SELL","transactionStatus":"COMPLETED"},
        {"transactionId":"t2","transactedOn":"2026-03-01T05:38:19.186Z",
         "category":"TRADEFEE","type":"DEBIT","assetSymbol":"OP",
         "amount":21.11,"amountType":"FIAT","orderId":"o1",
         "orderType":"SELL","transactionStatus":"COMPLETED"}]}}}
      """
    let resp = try JSONDecoder().decode(
      CoinstashGraphQLResponse<CoinstashTransactionsData>.self, from: Data(json.utf8))
    let page = try #require(resp.data?.accountTransactions)
    #expect(page.totalRecordsFound == 2)
    #expect(page.result.count == 2)
    #expect(page.result[0].transactionId == "t1")
    #expect(page.result[0].orderId == "o1")
    #expect(page.result[0].amount == Decimal(string: "3518.46"))
    #expect(page.result[1].amount == Decimal(string: "21.11"))
  }

  @Test
  func surfacesGraphQLErrors() throws {
    let json = """
      {"errors":[{"message":"Unauthorized"}]}
      """
    let resp = try JSONDecoder().decode(
      CoinstashGraphQLResponse<CoinstashTransactionsData>.self, from: Data(json.utf8))
    #expect(resp.data == nil)
    #expect(resp.errors.first?.message == "Unauthorized")
  }
}
