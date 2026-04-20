import Foundation

@testable import Moolah

/// Bundle-based lookup for CSV fixture files under `MoolahTests/Support/Fixtures/csv/`.
/// Uses `TestBundleMarker` as the bundle anchor.
enum CSVFixtureLoader {

  static func url(_ name: String) -> URL {
    guard
      let url = Bundle(for: TestBundleMarker.self).url(forResource: name, withExtension: "csv")
    else {
      fatalError("CSV fixture not found: \(name).csv")
    }
    return url
  }

  static func data(_ name: String) throws -> Data {
    try Data(contentsOf: url(name))
  }

  /// UTF-8 decoded contents. For fixtures in other encodings, use `data(_:)`
  /// and run through `CSVTokenizer.parse(_: Data)` which auto-detects.
  static func string(_ name: String) throws -> String {
    try String(contentsOf: url(name), encoding: .utf8)
  }
}
