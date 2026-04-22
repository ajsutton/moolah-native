import Foundation
import Testing

@testable import Moolah

@Suite("CSVTokenizer")
struct CSVTokenizerTests {

  @Test("parses a plain CSV with LF line endings")
  func parsesPlainLF() {
    let rows = CSVTokenizer.parse("a,b,c\n1,2,3\n4,5,6\n")
    #expect(rows == [["a", "b", "c"], ["1", "2", "3"], ["4", "5", "6"]])
  }

  @Test("parses CRLF line endings")
  func parsesCRLFLineEndings() {
    let rows = CSVTokenizer.parse("a,b\r\n1,2\r\n")
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test("parses CR line endings")
  func parsesCRLineEndings() {
    let rows = CSVTokenizer.parse("a,b\r1,2\r")
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test("strips UTF-8 BOM")
  func stripsUTF8BOM() {
    let rows = CSVTokenizer.parse("\u{FEFF}a,b\n1,2\n")
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test("preserves commas inside quoted fields")
  func preservesQuotedCommas() {
    let rows = CSVTokenizer.parse("a,\"b,c\",d\n")
    #expect(rows == [["a", "b,c", "d"]])
  }

  @Test("preserves newlines inside quoted fields")
  func preservesQuotedNewlines() {
    let rows = CSVTokenizer.parse("a,\"b\nc\",d\n")
    #expect(rows == [["a", "b\nc", "d"]])
  }

  @Test("handles escaped double-quotes inside quoted fields")
  func handlesEscapedQuotes() {
    let rows = CSVTokenizer.parse("\"she said \"\"hi\"\"\",x\n")
    #expect(rows == [["she said \"hi\"", "x"]])
  }

  @Test("drops standalone blank lines between records")
  func dropsStandaloneBlankLines() {
    let rows = CSVTokenizer.parse("a,b\n\n1,2\n")
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test("handles missing trailing newline")
  func handlesMissingTrailingNewline() {
    let rows = CSVTokenizer.parse("a,b\n1,2")
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test("empty string yields an empty row list")
  func emptyStringYieldsEmpty() {
    let rows = CSVTokenizer.parse("")
    #expect(rows.isEmpty)
  }

  @Test("keeps leading spaces on unquoted fields")
  func handlesFieldsWithLeadingSpaces() {
    let rows = CSVTokenizer.parse("a, b,c\n")
    #expect(rows == [["a", " b", "c"]])
  }

  @Test("empty fields between commas become empty strings")
  func parsesEmptyFieldsBetweenCommas() {
    let rows = CSVTokenizer.parse("a,,b\n")
    #expect(rows == [["a", "", "b"]])
  }

  @Test("trailing comma produces a trailing empty field")
  func trailingCommaProducesEmptyField() {
    let rows = CSVTokenizer.parse("a,b,\n")
    #expect(rows == [["a", "b", ""]])
  }

  @Test("parses UTF-8 bytes")
  func parseDataUtf8() throws {
    let data = "a,b\n".data(using: .utf8)!
    let rows = try CSVTokenizer.parse(data)
    #expect(rows == [["a", "b"]])
  }

  @Test("parses UTF-16 bytes")
  func parseDataUtf16() throws {
    let data = "a,b\n".data(using: .utf16)!
    let rows = try CSVTokenizer.parse(data)
    #expect(rows == [["a", "b"]])
  }

  @Test("parses Windows-1252 bytes containing non-ASCII characters")
  func parseDataWindows1252() throws {
    let data = "café,b\n".data(using: .windowsCP1252)!
    let rows = try CSVTokenizer.parse(data)
    #expect(rows == [["café", "b"]])
  }

}
