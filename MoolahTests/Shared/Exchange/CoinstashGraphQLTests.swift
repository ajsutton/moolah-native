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
         "category":"TRADE","type":"CREDIT","symbol":"AUD",
         "amount":3518.46,"amountType":"FIAT","orderId":"o1",
         "orderType":"SELL","transactionStatus":"COMPLETED"},
        {"transactionId":"t2","transactedOn":"2026-03-01T05:38:19.186Z",
         "category":"TRADEFEE","type":"DEBIT","symbol":"AUD",
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

  /// `symbol` is the per-leg currency (always populated). `assetSymbol`
  /// (the order's traded asset, `null` on deposits/awards) is intentionally
  /// not decoded — see `CoinstashClient` mapping.
  @Test
  func decodesPerLegSymbol() throws {
    let json = """
      {"data":{"accountTransactions":{"isSuccessful":true,
        "totalRecordsFound":2,"result":[
        {"transactionId":"t1","transactedOn":"2026-03-01T05:38:19.186Z",
         "category":"TRADE","type":"DEBIT","symbol":"OP",
         "amount":20167,"amountType":"ASSET","orderId":"o1",
         "transactionStatus":"COMPLETED"},
        {"transactionId":"t2","transactedOn":"2026-03-01T05:38:19.186Z",
         "category":"AWARD","type":"CREDIT","symbol":"BTC",
         "amount":0.00005492,"amountType":"ASSET",
         "transactionStatus":"COMPLETED"}]}}}
      """
    let resp = try JSONDecoder().decode(
      CoinstashGraphQLResponse<CoinstashTransactionsData>.self, from: Data(json.utf8))
    let page = try #require(resp.data?.accountTransactions)
    #expect(page.result[0].symbol == "OP")
    #expect(page.result[1].symbol == "BTC")
  }

  @Test
  func decodesTransactionWithOptionalFieldsAbsent() throws {
    let json = """
      {"data":{"accountTransactions":{"isSuccessful":true,
        "totalRecordsFound":1,"result":[
        {"transactionId":"t3","transactedOn":"2026-03-01T05:38:19.186Z",
         "category":"DEPOSIT","type":"CREDIT",
         "amount":100.00,"amountType":"FIAT","transactionStatus":"COMPLETED"}]}}}
      """
    let resp = try JSONDecoder().decode(
      CoinstashGraphQLResponse<CoinstashTransactionsData>.self, from: Data(json.utf8))
    let transaction = try #require(resp.data?.accountTransactions.result.first)
    #expect(transaction.symbol == nil)
    #expect(transaction.quoteBuyPrice == nil)
    #expect(transaction.orderId == nil)
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
