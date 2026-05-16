import Foundation

enum CoinstashGraphQL {
  // String-literal URL: a parse failure is a programming error, not runtime input.
  static let endpoint = URL(string: "https://graph.coinstash.com.au/graphql")!  // swiftlint:disable:this force_unwrapping

  static let userProfileQuery = """
    query { userProfile { userId } }
    """

  static let userAccountsQuery = """
    query Q($userId: ID!) {
      getUserAccounts(userId: $userId) { accounts { accountId accountType } }
    }
    """

  static let transactionsQuery = """
    query Q($a: ID!, $p: SearchAccountTransactionsPayloadInput) {
      accountTransactions(accountId: $a, searchAccountTransactionsPayloadInput: $p) {
        isSuccessful errorMessage totalRecordsFound
        result { transactionId transactedOn category type assetSymbol
                 amount amountType quoteBuyPrice quoteSellPrice
                 orderId orderType transactionStatus }
      }
    }
    """
}

struct CoinstashGraphQLError: Decodable, Sendable { let message: String }

struct CoinstashGraphQLResponse<T: Decodable & Sendable>: Decodable, Sendable {
  let data: T?
  // GraphQL: the "errors" key is absent on success; absent = empty here.
  let errors: [CoinstashGraphQLError]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    data = try container.decodeIfPresent(T.self, forKey: .data)
    errors = try container.decodeIfPresent([CoinstashGraphQLError].self, forKey: .errors) ?? []
  }

  private enum CodingKeys: CodingKey { case data, errors }
}

struct CoinstashUserProfileData: Decodable, Sendable {
  struct Profile: Decodable, Sendable { let userId: String }

  let userProfile: Profile
}

struct CoinstashUserAccountsData: Decodable, Sendable {
  struct AccountSummary: Decodable, Sendable {
    let accountId: String
    let accountType: String
  }

  struct GetUserAccountsResult: Decodable, Sendable {
    let accounts: [AccountSummary]
  }

  let getUserAccounts: GetUserAccountsResult
}

struct CoinstashTransaction: Decodable, Sendable, Hashable {
  let transactionId: String
  let transactedOn: String
  let category: String
  let type: String
  let assetSymbol: String?
  // Decimal (not Double): JSONDecoder decodes a bare JSON number into
  // Decimal losslessly. Double would corrupt amounts (3518.46 →
  // 3518.4599999999998) before they ever reach a TransactionLeg.
  let amount: Decimal
  let amountType: String
  let quoteBuyPrice: Decimal?
  let quoteSellPrice: Decimal?
  let orderId: String?
  let orderType: String?
  let transactionStatus: String
}

struct CoinstashTransactionsData: Decodable, Sendable {
  struct Page: Decodable, Sendable {
    let isSuccessful: Bool
    let errorMessage: String?
    let totalRecordsFound: Int
    let result: [CoinstashTransaction]
  }

  let accountTransactions: Page
}
