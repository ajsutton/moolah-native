import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore -- Conversion")
@MainActor
struct AccountStoreConversionTests {

  @Test
  func singleCurrencyAccountPositions() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: dec("1000.00"),
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [transaction], in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 1)
    #expect(positions.first?.instrument == .AUD)
    // Quantity will be from storage (Int64 scaled), so compare with tolerance
    #expect(positions.first?.quantity == dec("1000.00"))
  }

  @Test
  func multiCurrencyAccountShowsMultiplePositions() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank,
      instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let tx1 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: dec("1000.00"),
          type: .openingBalance
        )
      ]
    )
    let tx2 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .USD,
          quantity: dec("500.00"),
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [tx1, tx2], in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 2)
    #expect(
      positions.contains(where: {
        $0.instrument == .AUD && $0.quantity == dec("1000.00")
      }))
    #expect(
      positions.contains(where: {
        $0.instrument == .USD && $0.quantity == dec("500.00")
      }))
  }

  @Test
  func convertedTotalSumsAllPositionsInProfileCurrency() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank,
      instrument: .defaultTestInstrument)
    let todayString = Date().iso8601DateOnlyString
    let rates: [String: [String: Decimal]] = [
      todayString: [
        "AUD": dec("1.5385")
      ]
    ]
    let (backend, container) = try TestBackend.create(exchangeRates: rates)
    TestBackend.seed(accounts: [account], in: container)

    let tx1 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: dec("1000.00"),
          type: .openingBalance
        )
      ]
    )
    let tx2 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .USD,
          quantity: dec("500.00"),
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [tx1, tx2], in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    // 1000 AUD + 500 USD converted to AUD (500 * 1.5385 = 769.25)
    let total = try await store.computeConvertedCurrentTotal(in: .AUD)
    let expectedUsdInAud = dec("500.00") * dec("1.5385")
    let expected = dec("1000.00") + expectedUsdInAud
    #expect(total.quantity == expected)
    #expect(total.instrument == .AUD)
  }

  @Test
  func positionsForUnknownAccountReturnsEmpty() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()
    #expect(store.positions(for: UUID()).isEmpty)
  }
}
