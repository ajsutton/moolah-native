import CloudKit
import Foundation
import SwiftData

@testable import Moolah

enum ProfileDataSyncHandlerTestSupport {
  @MainActor
  static func makeHandler() throws -> (ProfileDataSyncHandler, ModelContainer) {
    let container = try TestModelContainer.create()
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    let handler = ProfileDataSyncHandler(
      profileId: profileId, zoneID: zoneID, modelContainer: container)
    return (handler, container)
  }
}
