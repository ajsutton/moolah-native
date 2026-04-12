/// Compatibility helpers for migrating tests from old MonetaryAmount/Currency/Transaction types
/// to the new InstrumentAmount/Instrument/leg-based Transaction types.

import Foundation

@testable import Moolah

// MARK: - MonetaryAmount compatibility

/// Free function that creates InstrumentAmount from old-style cents + instrument.
/// Usage: `MonetaryAmount(cents: 5000, currency: .AUD)` returns an InstrumentAmount.
func MonetaryAmount(cents: Int, currency: Instrument) -> InstrumentAmount {
  InstrumentAmount(quantity: Decimal(cents) / 100, instrument: currency)
}

// MARK: - InstrumentAmount.cents compatibility

extension InstrumentAmount {
  /// Convenience for tests that still reference `.cents`.
  var cents: Int {
    Int(truncating: (quantity * 100) as NSDecimalNumber)
  }

  /// Old `.currency` property - maps to `.instrument`
  var currency: Instrument { instrument }

  /// Old-style zero factory
  static func zero(currency: Instrument) -> InstrumentAmount {
    .zero(instrument: currency)
  }
}

// MARK: - Currency type alias

typealias Currency = Instrument

// MARK: - Instrument compatibility

extension Instrument {
  /// Old Currency.from(code:) factory
  static func from(code: String) -> Instrument {
    Instrument.fiat(code: code)
  }

  /// Old Currency.code property (now it's .id)
  var code: String { id }
}

// MARK: - Old-style Transaction convenience init

extension Transaction {
  /// Compatibility init for tests using the old flat Transaction constructor.
  init(
    id: UUID = UUID(),
    type: TransactionType,
    date: Date,
    accountId: UUID? = nil,
    toAccountId: UUID? = nil,
    amount: InstrumentAmount,
    payee: String? = nil,
    notes: String? = nil,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil,
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int? = nil
  ) {
    let instrument = amount.instrument
    let quantity = amount.quantity

    var legs: [TransactionLeg] = []

    if type == .transfer {
      if let acctId = accountId {
        legs.append(
          TransactionLeg(
            accountId: acctId, instrument: instrument, quantity: quantity, type: .transfer,
            categoryId: categoryId, earmarkId: earmarkId
          ))
      }
      if let toAcctId = toAccountId {
        legs.append(
          TransactionLeg(
            accountId: toAcctId, instrument: instrument, quantity: -quantity, type: .transfer
          ))
      }
    } else {
      if let acctId = accountId {
        legs.append(
          TransactionLeg(
            accountId: acctId, instrument: instrument, quantity: quantity, type: type,
            categoryId: categoryId, earmarkId: earmarkId
          ))
      } else {
        legs.append(
          TransactionLeg(
            accountId: UUID(), instrument: instrument, quantity: quantity, type: type,
            categoryId: categoryId, earmarkId: earmarkId
          ))
      }
    }

    self.init(
      id: id, date: date, payee: payee, notes: notes,
      recurPeriod: recurPeriod, recurEvery: recurEvery, legs: legs
    )
  }

  /// Old-style convenience accessors for test compatibility.
  var amount: InstrumentAmount {
    get { primaryAmount }
    set {
      if let firstLeg = legs.first {
        let newLeg = TransactionLeg(
          accountId: firstLeg.accountId,
          instrument: newValue.instrument,
          quantity: newValue.quantity,
          type: firstLeg.type,
          categoryId: firstLeg.categoryId,
          earmarkId: firstLeg.earmarkId
        )
        legs = [newLeg] + Array(legs.dropFirst())
      }
    }
  }

  var accountId: UUID? {
    get { primaryAccountId }
    set {
      guard let newValue, let firstLeg = legs.first else { return }
      let newLeg = TransactionLeg(
        accountId: newValue, instrument: firstLeg.instrument, quantity: firstLeg.quantity,
        type: firstLeg.type, categoryId: firstLeg.categoryId, earmarkId: firstLeg.earmarkId
      )
      legs = [newLeg] + Array(legs.dropFirst())
    }
  }

  var earmarkId: UUID? {
    get { legs.first?.earmarkId }
    set {
      guard let firstLeg = legs.first else { return }
      let newLeg = TransactionLeg(
        accountId: firstLeg.accountId, instrument: firstLeg.instrument, quantity: firstLeg.quantity,
        type: firstLeg.type, categoryId: firstLeg.categoryId, earmarkId: newValue
      )
      legs = [newLeg] + Array(legs.dropFirst())
    }
  }

  /// Setter for earmarkId on the first leg (test compatibility, immutable version).
  func withEarmarkId(_ earmarkId: UUID?) -> Transaction {
    var copy = self
    copy.earmarkId = earmarkId
    return copy
  }

  var toAccountId: UUID? {
    get {
      guard legs.count > 1 else { return nil }
      return legs.first(where: { $0.accountId != primaryAccountId })?.accountId
    }
    set {
      if legs.count > 1 {
        // Update existing second leg
        let secondLeg = legs[1]
        let newLeg = TransactionLeg(
          accountId: newValue ?? secondLeg.accountId, instrument: secondLeg.instrument,
          quantity: secondLeg.quantity, type: secondLeg.type,
          categoryId: secondLeg.categoryId, earmarkId: secondLeg.earmarkId
        )
        legs = [legs[0], newLeg] + Array(legs.dropFirst(2))
      } else if let newValue, let firstLeg = legs.first {
        // Add a second leg for transfer
        legs.append(
          TransactionLeg(
            accountId: newValue, instrument: firstLeg.instrument,
            quantity: -firstLeg.quantity, type: .transfer
          ))
      }
    }
  }

  /// Type is computed from first leg. Setting it rebuilds the first leg.
  /// When changing from transfer to non-transfer, removes extra legs.
  var type: TransactionType {
    get { legs.first?.type ?? .expense }
    set {
      guard let firstLeg = legs.first else { return }
      let newLeg = TransactionLeg(
        accountId: firstLeg.accountId, instrument: firstLeg.instrument, quantity: firstLeg.quantity,
        type: newValue, categoryId: firstLeg.categoryId, earmarkId: firstLeg.earmarkId
      )
      if newValue != .transfer {
        // Non-transfer: keep only the first leg
        legs = [newLeg]
      } else {
        legs = [newLeg] + Array(legs.dropFirst())
      }
    }
  }
}
