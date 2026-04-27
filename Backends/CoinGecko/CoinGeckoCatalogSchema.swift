// Backends/CoinGecko/CoinGeckoCatalogSchema.swift
import Foundation

/// Single source of truth for the CoinGecko-catalogue SQLite schema.
/// Bump `version` whenever the on-disk shape changes; the catalogue
/// implementation drops and recreates the file rather than running a
/// migration.
enum CoinGeckoCatalogSchema {
  static let version: Int = 1

  static let statements: [String] = [
    "PRAGMA journal_mode = WAL;",
    "PRAGMA foreign_keys = ON;",

    """
    CREATE TABLE meta (
      schema_version  INTEGER NOT NULL,
      last_fetched    REAL,
      coins_etag      TEXT,
      platforms_etag  TEXT
    );
    """,

    "INSERT INTO meta (schema_version) VALUES (\(version));",

    """
    CREATE TABLE coin (
      rowid          INTEGER PRIMARY KEY,
      coingecko_id   TEXT NOT NULL UNIQUE,
      symbol         TEXT NOT NULL,
      name           TEXT NOT NULL
    );
    """,

    """
    CREATE TABLE coin_platform (
      coingecko_id     TEXT NOT NULL,
      platform_slug    TEXT NOT NULL,
      contract_address TEXT NOT NULL,
      PRIMARY KEY (coingecko_id, platform_slug),
      FOREIGN KEY (coingecko_id) REFERENCES coin(coingecko_id) ON DELETE CASCADE
    );
    """,

    """
    CREATE INDEX coin_platform_chain_contract
      ON coin_platform(platform_slug, contract_address);
    """,

    """
    CREATE TABLE platform (
      slug      TEXT PRIMARY KEY,
      chain_id  INTEGER,
      name      TEXT NOT NULL
    );
    """,

    """
    CREATE VIRTUAL TABLE coin_fts USING fts5(
      symbol, name,
      content='coin',
      content_rowid='rowid',
      tokenize='unicode61 remove_diacritics 1'
    );
    """,

    """
    CREATE TRIGGER coin_ai AFTER INSERT ON coin BEGIN
      INSERT INTO coin_fts(rowid, symbol, name) VALUES (new.rowid, new.symbol, new.name);
    END;
    """,

    """
    CREATE TRIGGER coin_ad AFTER DELETE ON coin BEGIN
      INSERT INTO coin_fts(coin_fts, rowid, symbol, name)
      VALUES('delete', old.rowid, old.symbol, old.name);
    END;
    """,

    """
    CREATE TRIGGER coin_au AFTER UPDATE ON coin BEGIN
      INSERT INTO coin_fts(coin_fts, rowid, symbol, name)
      VALUES('delete', old.rowid, old.symbol, old.name);
      INSERT INTO coin_fts(rowid, symbol, name) VALUES (new.rowid, new.symbol, new.name);
    END;
    """,
  ]

  /// Built-in priority order for picking a coin's preferred chain when it
  /// is listed on multiple platforms. Slugs not in this list fall through
  /// to the order returned from SQLite.
  static let platformPriority: [String] = [
    "ethereum",
    "polygon-pos",
    "binance-smart-chain",
    "base",
    "arbitrum-one",
    "optimism",
    "avalanche",
  ]
}
