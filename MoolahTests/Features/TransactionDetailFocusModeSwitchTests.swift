import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDetailFocus.remapping(toStructure:)")
struct TransactionDetailFocusModeSwitchTests {
  private typealias ModeStructure = TransactionDetailFocus.ModeStructure

  @Test
  func payeeStaysPutAcrossEveryStructure() {
    #expect(TransactionDetailFocus.payee.remapping(toStructure: .simple) == .payee)
    #expect(TransactionDetailFocus.payee.remapping(toStructure: .trade) == .payee)
    #expect(TransactionDetailFocus.payee.remapping(toStructure: .custom) == .payee)
  }

  @Test
  func amountMapsToTheNewStructuresPrimaryAmount() {
    #expect(TransactionDetailFocus.amount.remapping(toStructure: .simple) == .amount)
    #expect(
      TransactionDetailFocus.amount.remapping(toStructure: .trade) == .tradePaidAmount)
    #expect(
      TransactionDetailFocus.amount.remapping(toStructure: .custom) == .legAmount(0))
  }

  @Test
  func counterpartAmountMapsToTheNewStructuresPrimaryAmount() {
    let focus = TransactionDetailFocus.counterpartAmount
    #expect(focus.remapping(toStructure: .simple) == .amount)
    #expect(focus.remapping(toStructure: .trade) == .tradePaidAmount)
    #expect(focus.remapping(toStructure: .custom) == .legAmount(0))
  }

  @Test
  func legAmountStaysPutWithinCustomAndMapsOutOfCustom() {
    let focus = TransactionDetailFocus.legAmount(2)
    #expect(focus.remapping(toStructure: .custom) == .legAmount(2))
    #expect(focus.remapping(toStructure: .simple) == .amount)
    #expect(focus.remapping(toStructure: .trade) == .tradePaidAmount)
  }

  @Test
  func tradePaidAmountStaysWithinTradeAndMapsOutOfTrade() {
    let focus = TransactionDetailFocus.tradePaidAmount
    #expect(focus.remapping(toStructure: .trade) == .tradePaidAmount)
    #expect(focus.remapping(toStructure: .simple) == .amount)
    #expect(focus.remapping(toStructure: .custom) == .legAmount(0))
  }

  @Test
  func tradeReceivedAmountStaysWithinTradeAndMapsOutOfTrade() {
    let focus = TransactionDetailFocus.tradeReceivedAmount
    #expect(focus.remapping(toStructure: .trade) == .tradeReceivedAmount)
    #expect(focus.remapping(toStructure: .simple) == .amount)
    #expect(focus.remapping(toStructure: .custom) == .legAmount(0))
  }

  @Test
  func tradeFeeAmountStaysWithinTradeAndMapsOutOfTrade() {
    let focus = TransactionDetailFocus.tradeFeeAmount(1)
    #expect(focus.remapping(toStructure: .trade) == .tradeFeeAmount(1))
    #expect(focus.remapping(toStructure: .simple) == .amount)
    #expect(focus.remapping(toStructure: .custom) == .legAmount(0))
  }
}
