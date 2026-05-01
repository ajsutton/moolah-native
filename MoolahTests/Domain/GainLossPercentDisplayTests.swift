import Foundation
import Testing

@testable import Moolah

@Suite("GainLossPercentDisplay")
struct GainLossPercentDisplayTests {
  // MARK: - formatted(_:) — locale-aware decimal separator

  @Test("formatted uses dot decimal separator in en_US")
  func formattedUsesDotInEnUS() {
    let locale = Locale(identifier: "en_US")
    #expect(GainLossPercentDisplay.formatted(12.3, locale: locale) == "+12.3%")
    #expect(GainLossPercentDisplay.formatted(-4, locale: locale) == "−4.0%")
    #expect(GainLossPercentDisplay.formatted(0, locale: locale) == "0.0%")
  }

  @Test("formatted uses comma decimal separator in de_DE")
  func formattedUsesCommaInDeDE() {
    let locale = Locale(identifier: "de_DE")
    #expect(GainLossPercentDisplay.formatted(12.3, locale: locale) == "+12,3%")
    #expect(GainLossPercentDisplay.formatted(-4, locale: locale) == "−4,0%")
    #expect(GainLossPercentDisplay.formatted(0, locale: locale) == "0,0%")
  }

  @Test("formatted uses comma decimal separator in fr_FR")
  func formattedUsesCommaInFrFR() {
    let locale = Locale(identifier: "fr_FR")
    #expect(GainLossPercentDisplay.formatted(7.5, locale: locale) == "+7,5%")
    #expect(GainLossPercentDisplay.formatted(-12.34, locale: locale) == "−12,3%")
  }

  @Test("formatted rounds to one fraction digit")
  func formattedRoundsToOneFractionDigit() {
    let locale = Locale(identifier: "en_US")
    #expect(GainLossPercentDisplay.formatted(12.34, locale: locale) == "+12.3%")
    #expect(GainLossPercentDisplay.formatted(12.35, locale: locale) == "+12.4%")
    #expect(GainLossPercentDisplay.formatted(-12.36, locale: locale) == "−12.4%")
  }

  @Test("formatted uses Unicode minus (U+2212) for negatives")
  func formattedUsesUnicodeMinus() {
    let locale = Locale(identifier: "en_US")
    let result = GainLossPercentDisplay.formatted(-4, locale: locale)
    #expect(result.contains("\u{2212}"))
    #expect(!result.contains("-"))
  }

  // MARK: - accessibilitySuffix(_:) — locale-aware

  @Test("accessibilitySuffix uses dot decimal separator in en_US")
  func accessibilitySuffixUsesDotInEnUS() {
    let locale = Locale(identifier: "en_US")
    #expect(
      GainLossPercentDisplay.accessibilitySuffix(12.3, locale: locale) == ", up 12.3 percent")
    #expect(
      GainLossPercentDisplay.accessibilitySuffix(-4, locale: locale) == ", down 4.0 percent")
    #expect(GainLossPercentDisplay.accessibilitySuffix(0, locale: locale) == ", 0.0 percent")
  }

  @Test("accessibilitySuffix uses comma decimal separator in de_DE")
  func accessibilitySuffixUsesCommaInDeDE() {
    let locale = Locale(identifier: "de_DE")
    #expect(
      GainLossPercentDisplay.accessibilitySuffix(12.3, locale: locale) == ", up 12,3 percent")
    #expect(
      GainLossPercentDisplay.accessibilitySuffix(-4, locale: locale) == ", down 4,0 percent")
  }

  @Test("accessibilitySuffix returns empty string for nil input")
  func accessibilitySuffixEmptyForNil() {
    #expect(GainLossPercentDisplay.accessibilitySuffix(nil).isEmpty)
  }
}
