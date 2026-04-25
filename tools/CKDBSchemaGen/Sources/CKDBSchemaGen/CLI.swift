import Foundation

@main
enum CKDBSchemaGenCLI {

  static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
      switch args.first {
      case "generate":
        try runGenerate(args: Array(args.dropFirst()))
      case "check-additive":
        try runCheckAdditive(args: Array(args.dropFirst()))
      default:
        printUsage()
        exit(2)
      }
    } catch {
      fputs("ckdb-schema-gen: \(error)\n", stderr)
      exit(1)
    }
  }

  // MARK: - generate

  private static func runGenerate(args: [String]) throws {
    let opts = parseOptions(args, allowed: ["--input", "--output"])
    guard let input = opts["--input"], let output = opts["--output"] else {
      fputs("ckdb-schema-gen generate: --input <ckdb> --output <dir> required\n", stderr)
      exit(2)
    }
    let source = try String(contentsOfFile: input, encoding: .utf8)
    let schema = try Parser.parse(source)
    let files = Generator.generate(schema)
    try createDirectory(at: output)
    let existing = try existingGeneratedFiles(in: output)
    let written = try writeFiles(files, to: output)
    let stale = existing.subtracting(written)
    for path in stale {
      try FileManager.default.removeItem(atPath: path)
    }
    print("ckdb-schema-gen: wrote \(files.count) wire struct(s) to \(output)")
  }

  private static func createDirectory(at path: String) throws {
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true)
  }

  private static func existingGeneratedFiles(in directory: String) throws -> Set<String> {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
    return Set(
      entries
        .filter { $0.hasSuffix("CloudKitFields.swift") }
        .map { (directory as NSString).appendingPathComponent($0) }
    )
  }

  private static func writeFiles(_ files: [Generator.File], to directory: String) throws
    -> Set<String>
  {
    var written: Set<String> = []
    for file in files {
      let path = (directory as NSString).appendingPathComponent(file.path)
      try file.contents.write(toFile: path, atomically: true, encoding: .utf8)
      written.insert(path)
    }
    return written
  }

  // MARK: - check-additive

  private static func runCheckAdditive(args: [String]) throws {
    let opts = parseOptions(args, allowed: ["--proposed", "--baseline"])
    guard let proposed = opts["--proposed"], let baseline = opts["--baseline"] else {
      fputs(
        "ckdb-schema-gen check-additive: --proposed <ckdb> --baseline <ckdb> required\n", stderr)
      exit(2)
    }
    let proposedSource = try String(contentsOfFile: proposed, encoding: .utf8)
    let baselineSource = try String(contentsOfFile: baseline, encoding: .utf8)
    let proposedSchema = try Parser.parse(proposedSource)
    let baselineSchema = try Parser.parse(baselineSource)
    let result = Additivity.check(proposed: proposedSchema, baseline: baselineSchema)
    if result.violations.isEmpty {
      print("ckdb-schema-gen: \(proposed) is additive over \(baseline)")
      return
    }
    fputs("ckdb-schema-gen: schema is not additive over baseline:\n", stderr)
    for violation in result.violations {
      fputs("  - \(violation)\n", stderr)
    }
    exit(1)
  }

  // MARK: - shared

  private static func parseOptions(_ args: [String], allowed: Set<String>) -> [String: String] {
    var i = 0
    var out: [String: String] = [:]
    while i < args.count {
      let key = args[i]
      guard allowed.contains(key), i + 1 < args.count else {
        i += 1
        continue
      }
      out[key] = args[i + 1]
      i += 2
    }
    return out
  }

  private static func printUsage() {
    fputs(
      """
      Usage:
        ckdb-schema-gen generate --input <schema.ckdb> --output <dir>
        ckdb-schema-gen check-additive --proposed <schema.ckdb> --baseline <baseline.ckdb>
      """,
      stderr)
    fputs("\n", stderr)
  }
}
