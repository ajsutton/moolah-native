// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CKDBSchemaGen",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "ckdb-schema-gen", targets: ["CKDBSchemaGen"])
  ],
  targets: [
    .executableTarget(name: "CKDBSchemaGen"),
    .testTarget(name: "CKDBSchemaGenTests", dependencies: ["CKDBSchemaGen"]),
  ]
)
