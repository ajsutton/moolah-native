@preconcurrency import CloudKit
import Foundation

/// Resolves the CloudKit container the app should use, in place of
/// `CKContainer.default()`.
///
/// `CKContainer.default()` matches by bundle identifier and falls back to
/// the first entry in `com.apple.developer.icloud-container-identifiers`
/// when no bundle-ID match exists. That implicit selection has caught the
/// app out before — when the developer team has multiple containers
/// associated with the App ID, automatic provisioning can include all of
/// them in the signed entitlements, and the resolved identifier becomes a
/// function of array order rather than intent.
///
/// The identifier is sourced from the `CLOUDKIT_CONTAINER_ID` build
/// setting (project.yml), surfaced as the `MoolahCloudKitContainer`
/// Info.plist key, and read here. Any drift between the build setting,
/// the entitlements file, and the schema scripts is therefore a single
/// audit point.
enum CloudKitContainer {
  static let app: CKContainer = {
    let key = "MoolahCloudKitContainer"
    guard
      let identifier = Bundle.main.object(forInfoDictionaryKey: key) as? String,
      !identifier.isEmpty
    else {
      preconditionFailure(
        "Info.plist key '\(key)' missing — set CLOUDKIT_CONTAINER_ID in project.yml"
      )
    }
    return CKContainer(identifier: identifier)
  }()
}
