import Foundation
import OSLog

/// Computes per-account display balances and aggregate totals for
/// `AccountStore`, isolating the conversion-service orchestration from the
/// store's state management and mutation responsibilities.
///
/// A single `compute(...)` call iterates every account in isolation, so one
/// failure doesn't block balances for other accounts. Aggregate totals are
/// only non-nil when *all* contributing accounts converted successfully —
/// an inaccurate aggregate is worse than no aggregate.
///
/// Callers (the store) re-invoke `compute` from a retry loop until nothing
/// fails; the calculator itself holds no retry state.
@MainActor
struct AccountBalanceCalculator {
  let conversionService: any InstrumentConversionService
  let targetInstrument: Instrument

  /// Everything the store needs to publish after a single conversion pass.
  struct Snapshot: Sendable {
    let balances: [UUID: InstrumentAmount]
    let currentTotal: InstrumentAmount?
    let investmentTotal: InstrumentAmount?
    let netWorth: InstrumentAmount?
    let anyFailed: Bool
  }

  private var logger: Logger {
    Logger(subsystem: "com.moolah.app", category: "AccountBalanceCalculator")
  }

  /// Computes a snapshot of per-account balances + aggregates. Honours
  /// `Task.isCancelled` between phases; when cancelled, returns a snapshot
  /// flagged `anyFailed = false` so callers short-circuit without re-trying.
  func compute(
    allAccounts: [Account],
    currentAccounts: [Account],
    investmentAccounts: [Account],
    investmentValues: InvestmentValueCache
  ) async -> Snapshot {
    var anyFailed = false
    var newBalances: [UUID: InstrumentAmount] = [:]

    // Phase 1: per-account display balance in the account's own instrument.
    // Iterate all accounts so per-account display works regardless of showHidden.
    for account in allAccounts {
      do {
        let balance = try await displayBalance(
          for: account, investmentValue: investmentValues.value(for: account.id))
        guard !Task.isCancelled else { return cancelledSnapshot() }
        newBalances[account.id] = balance
      } catch {
        anyFailed = true
        logger.warning(
          "Conversion failed for account \(account.name): \(error.localizedDescription)")
      }
    }

    // Phase 2: aggregate totals — only valid when every contributing account
    // converted successfully *and* the per-account → target conversion works.
    let date = Date()
    let (currentTotal, currentValid) = await sumConverted(
      accounts: currentAccounts, balances: newBalances, on: date)
    let (investmentTotal, investmentValid) = await sumConverted(
      accounts: investmentAccounts, balances: newBalances, on: date)

    guard !Task.isCancelled else { return cancelledSnapshot() }

    if !currentValid || !investmentValid { anyFailed = true }

    return Snapshot(
      balances: newBalances,
      currentTotal: currentValid ? currentTotal : nil,
      investmentTotal: investmentValid ? investmentTotal : nil,
      netWorth: (currentValid && investmentValid) ? (currentTotal + investmentTotal) : nil,
      anyFailed: anyFailed
    )
  }

  /// Sum all positions across `accounts`, converted to `target`. When
  /// `investmentValues` is provided and the account has an externally-set
  /// value, that amount is used verbatim (converted once) — avoiding the
  /// double-conversion a naive `positions → account instrument → target`
  /// implementation would incur on investment aggregates.
  func totalConverted(
    for accounts: [Account],
    to target: Instrument,
    using investmentValues: InvestmentValueCache? = nil
  ) async throws -> InstrumentAmount {
    var total = InstrumentAmount.zero(instrument: target)
    let date = Date()
    for account in accounts {
      if let investmentValues, let externalValue = investmentValues.value(for: account.id) {
        total += try await conversionService.convertAmount(externalValue, to: target, on: date)
        continue
      }
      for position in account.positions {
        total += try await conversionService.convertAmount(position.amount, to: target, on: date)
      }
    }
    return total
  }

  /// The display balance for an account in its own instrument. Investment
  /// accounts with an externally-provided value return that; otherwise the
  /// method sums every position converted via the conversion service.
  func displayBalance(
    for account: Account, investmentValue: InstrumentAmount?
  ) async throws -> InstrumentAmount {
    if account.type == .investment, let investmentValue {
      return investmentValue
    }
    var total = InstrumentAmount.zero(instrument: account.instrument)
    let date = Date()
    for position in account.positions {
      total += try await conversionService.convertAmount(
        position.amount, to: account.instrument, on: date)
    }
    return total
  }

  /// Sums the per-account balances converted to `targetInstrument`. Returns
  /// `(total, valid)`; `valid` is false if any account is missing from
  /// `balances` or if its target conversion throws.
  private func sumConverted(
    accounts list: [Account],
    balances: [UUID: InstrumentAmount],
    on date: Date
  ) async -> (InstrumentAmount, Bool) {
    var total = InstrumentAmount.zero(instrument: targetInstrument)
    var valid = true
    for account in list {
      guard let balance = balances[account.id] else {
        valid = false
        continue
      }
      do {
        let converted = try await conversionService.convertAmount(
          balance, to: targetInstrument, on: date)
        if valid { total += converted }
      } catch {
        valid = false
        logger.warning(
          "Aggregate conversion failed for \(account.name): \(error.localizedDescription)")
      }
    }
    return (total, valid)
  }

  private func cancelledSnapshot() -> Snapshot {
    Snapshot(
      balances: [:], currentTotal: nil, investmentTotal: nil, netWorth: nil, anyFailed: false)
  }
}
