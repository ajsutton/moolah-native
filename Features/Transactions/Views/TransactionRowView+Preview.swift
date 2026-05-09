// swiftlint:disable multiline_arguments

import SwiftUI

extension TransactionRowView {
  struct PreviewData {
    let sourceId = UUID()
    let savingsId = UUID()
    let groceriesId = UUID()
    let holidayFundId = UUID()

    var accounts: Accounts {
      Accounts(from: [
        Account(
          id: savingsId, name: "Savings", type: .bank, instrument: .AUD,
          positions: [Position(instrument: .AUD, quantity: 5000)])
      ])
    }
    var categories: Categories {
      Categories(from: [
        Category(id: groceriesId, name: "Groceries"),
        Category(name: "Transport"),
      ])
    }
    var earmarks: Earmarks {
      Earmarks(from: [
        Earmark(id: holidayFundId, name: "Holiday Fund", instrument: .AUD)
      ])
    }
  }

  struct PreviewRowSpec {
    let payee: String?
    let legs: [TransactionLeg]
    let displayAmounts: [InstrumentAmount]
    let balance: Decimal
    var viewingAccountId: UUID?
  }
}

@MainActor
private func previewRow(
  data: TransactionRowView.PreviewData,
  payee: String? = nil,
  legs: [TransactionLeg],
  displayAmounts: [InstrumentAmount],
  balance: Decimal,
  scopeReferenceInstrument: Instrument = .AUD,
  viewingAccountId: UUID? = nil
) -> TransactionRowView {
  TransactionRowView(
    transaction: Transaction(date: Date(), payee: payee ?? "", legs: legs),
    accounts: data.accounts, categories: data.categories, earmarks: data.earmarks,
    displayAmounts: displayAmounts,
    balance: InstrumentAmount(quantity: balance, instrument: .AUD),
    scopeReferenceInstrument: scopeReferenceInstrument,
    viewingAccountId: viewingAccountId)
}

private func previewRowSpecs(
  data: TransactionRowView.PreviewData
) -> [TransactionRowView.PreviewRowSpec] {
  simplePreviewSpecs(data: data) + tradePreviewSpecs(data: data)
}

private func simplePreviewSpecs(
  data: TransactionRowView.PreviewData
) -> [TransactionRowView.PreviewRowSpec] {
  [
    TransactionRowView.PreviewRowSpec(
      payee: "Woolworths",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -50.23, type: .expense,
          categoryId: data.groceriesId)
      ],
      displayAmounts: [InstrumentAmount(quantity: -50.23, instrument: .AUD)],
      balance: 1000),
    TransactionRowView.PreviewRowSpec(
      payee: "Employer Pty Ltd",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: 3500, type: .income,
          earmarkId: data.holidayFundId)
      ],
      displayAmounts: [InstrumentAmount(quantity: 3500, instrument: .AUD)],
      balance: 1050.23),
    TransactionRowView.PreviewRowSpec(
      payee: nil,
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 1000, type: .transfer),
      ],
      displayAmounts: [InstrumentAmount(quantity: -1000, instrument: .AUD)],
      balance: -2449.77, viewingAccountId: data.sourceId),
    TransactionRowView.PreviewRowSpec(
      payee: "Rent Split",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -500, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 500, type: .transfer),
      ],
      displayAmounts: [InstrumentAmount(quantity: -500, instrument: .AUD)],
      balance: -1449.77, viewingAccountId: data.sourceId),
  ]
}

private func tradePreviewSpecs(
  data: TransactionRowView.PreviewData
) -> [TransactionRowView.PreviewRowSpec] {
  [
    TransactionRowView.PreviewRowSpec(
      payee: "Stock Trade",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 950, type: .transfer),
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -50, type: .expense),
      ],
      displayAmounts: [
        InstrumentAmount(quantity: -1000, instrument: .AUD),
        InstrumentAmount(quantity: 950, instrument: .AUD),
        InstrumentAmount(quantity: -50, instrument: .AUD),
      ],
      balance: -2499.77, viewingAccountId: data.sourceId)
  ]
}

#Preview {
  let data = TransactionRowView.PreviewData()
  return List {
    ForEach(Array(previewRowSpecs(data: data).enumerated()), id: \.offset) { _, spec in
      previewRow(
        data: data, payee: spec.payee, legs: spec.legs,
        displayAmounts: spec.displayAmounts, balance: spec.balance,
        viewingAccountId: spec.viewingAccountId)
    }
  }
}
