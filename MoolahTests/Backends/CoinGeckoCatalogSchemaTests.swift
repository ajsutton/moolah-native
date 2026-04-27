// MoolahTests/Backends/CoinGeckoCatalogSchemaTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CoinGeckoCatalogSchema")
struct CoinGeckoCatalogSchemaTests {
  @Test
  func schemaVersionStartsAtOne() {
    #expect(CoinGeckoCatalogSchema.version == 1)
  }

  @Test
  func schemaContainsCoreTables() {
    let ddl = CoinGeckoCatalogSchema.statements.joined(separator: "\n")
    #expect(ddl.contains("CREATE TABLE meta"))
    #expect(ddl.contains("CREATE TABLE coin"))
    #expect(ddl.contains("CREATE TABLE coin_platform"))
    #expect(ddl.contains("CREATE TABLE platform"))
    #expect(ddl.contains("CREATE VIRTUAL TABLE coin_fts USING fts5"))
  }

  @Test
  func schemaInstallsFtsTriggers() {
    let ddl = CoinGeckoCatalogSchema.statements.joined(separator: "\n")
    #expect(ddl.contains("CREATE TRIGGER coin_ai"))
    #expect(ddl.contains("CREATE TRIGGER coin_ad"))
    #expect(ddl.contains("CREATE TRIGGER coin_au"))
  }
}
