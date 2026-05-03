import Foundation
import Testing

@testable import Moolah

/// `TransactionDraft.flipTradePaidDisplaySign(_:)` is the view-side bijection
/// that lets the trade Paid field display amounts in the user's natural sign:
/// the user types `300` to mean "I paid $300, balance goes down", and the
/// underlying leg quantity is stored as `-300`. The helper must round-trip
/// (`flip(flip(x)) == x`) so the Binding's get/set composition is stable, and
/// must pass partial input (`""`, `"-"`, `"0."`) through unchanged so typing
/// is not interrupted mid-keystroke.
@Suite("TransactionDraft.flipTradePaidDisplaySign")
struct TransactionDraftTradePaidDisplayTests {

  // MARK: - Round-trip cases (display ↔ storage)

  @Test("positive display flips to negative storage")
  func positiveToNegative() {
    #expect(TransactionDraft.flipTradePaidDisplaySign("300") == "-300")
    #expect(TransactionDraft.flipTradePaidDisplaySign("1") == "-1")
    #expect(TransactionDraft.flipTradePaidDisplaySign("10.5") == "-10.5")
    #expect(TransactionDraft.flipTradePaidDisplaySign("300.00") == "-300.00")
  }

  @Test("negative display flips to positive storage")
  func negativeToPositive() {
    #expect(TransactionDraft.flipTradePaidDisplaySign("-300") == "300")
    #expect(TransactionDraft.flipTradePaidDisplaySign("-1") == "1")
    #expect(TransactionDraft.flipTradePaidDisplaySign("-10.5") == "10.5")
    #expect(TransactionDraft.flipTradePaidDisplaySign("-300.00") == "300.00")
  }

  // MARK: - Zero handling (clean initial display)

  @Test("canonical zero stays positive — no '-0' rendered for fresh paid leg")
  func zeroStaysPositive() {
    // The blank Paid leg's stored amountText is "0"; users should see "0",
    // not "-0", in the field on a fresh trade form.
    #expect(TransactionDraft.flipTradePaidDisplaySign("0") == "0")
    #expect(TransactionDraft.flipTradePaidDisplaySign("0.") == "0.")
  }

  @Test("'-0' / '-0.' preserve the leading minus during partial typing of '-0.5'")
  func negativeZeroPreservedForTyping() {
    // User enters a refund (negative paid amount) by typing "-", "0", ".",
    // "5". The "-0" intermediate state must keep its minus so the next
    // keystroke continues building "-0.5" rather than collapsing to "0.5".
    #expect(TransactionDraft.flipTradePaidDisplaySign("-0") == "-0")
    #expect(TransactionDraft.flipTradePaidDisplaySign("-0.") == "-0.")
  }

  // MARK: - Partial input passthrough

  @Test("empty string passes through unchanged")
  func emptyPassesThrough() {
    #expect(TransactionDraft.flipTradePaidDisplaySign("").isEmpty)
  }

  @Test("lone '-' passes through unchanged so typing a refund's leading minus survives")
  func loneMinusPassesThrough() {
    #expect(TransactionDraft.flipTradePaidDisplaySign("-") == "-")
  }

  // MARK: - Idempotency under composition (Binding round-trip stability)

  @Test("flip(flip(x)) == x for typical values — Binding round-trip is stable")
  func idempotentUnderComposition() {
    let cases = [
      "", "-", "0", "0.", "-0", "-0.", "1", "-1", "10.", "10.5",
      "-10.5", "300.00", "-300.00", "0.5", "-0.5",
    ]
    for value in cases {
      let roundTripped = TransactionDraft.flipTradePaidDisplaySign(
        TransactionDraft.flipTradePaidDisplaySign(value))
      #expect(
        roundTripped == value,
        "flip(flip(\"\(value)\")) yielded \"\(roundTripped)\", expected \"\(value)\"")
    }
  }

  // MARK: - Typing simulations (keystroke-by-keystroke)

  @Test("typing '300' from empty — every intermediate state displays naturally")
  func typingPositiveAmount() {
    // Each keystroke: the displayed text is what we feed into the setter,
    // and the next render call re-flips storage back to the displayed text.
    // For positive entries the rendered value equals the typed value (no
    // phantom minus appearing mid-typing).
    var stored = ""
    for keystroke in ["3", "30", "300"] {
      stored = TransactionDraft.flipTradePaidDisplaySign(keystroke)
      let rendered = TransactionDraft.flipTradePaidDisplaySign(stored)
      #expect(rendered == keystroke, "after typing \"\(keystroke)\" rendered \"\(rendered)\"")
    }
    // Final storage is the negated leg quantity.
    #expect(stored == "-300")
  }

  @Test("typing '-0.5' from empty — '-' and '-0' intermediates are preserved")
  func typingNegativeRefundAmount() {
    var stored = ""
    let keystrokes = ["-", "-0", "-0.", "-0.5"]
    for display in keystrokes {
      stored = TransactionDraft.flipTradePaidDisplaySign(display)
      let rendered = TransactionDraft.flipTradePaidDisplaySign(stored)
      #expect(rendered == display, "after typing \"\(display)\" rendered \"\(rendered)\"")
    }
    // Final storage is the negated leg quantity.
    #expect(stored == "0.5")
  }

  @Test("typing '0.5' from empty — neither '0' nor '0.' grow a phantom minus")
  func typingFractionalAmount() {
    // For positive entries the rendered value equals the typed value at
    // every keystroke; the canonical-zero special-cases ensure "0" and "0."
    // do not flicker into "-0" / "-0." mid-typing.
    var stored = ""
    for keystroke in ["0", "0.", "0.5"] {
      stored = TransactionDraft.flipTradePaidDisplaySign(keystroke)
      let rendered = TransactionDraft.flipTradePaidDisplaySign(stored)
      #expect(rendered == keystroke, "after typing \"\(keystroke)\" rendered \"\(rendered)\"")
    }
    #expect(stored == "-0.5")
  }
}
