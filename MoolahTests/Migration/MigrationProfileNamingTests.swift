import Testing

@testable import Moolah

struct MigrationProfileNamingTests {

  // MARK: - Source profile naming (Remote suffix)

  @Test
  func sourceLabel_plainName_appendsRemote() {
    let result = MigrationProfileNaming.sourceLabel(for: "Moolah")
    #expect(result == "Moolah (Remote)")
  }

  @Test
  func sourceLabel_alreadyHasRemote_unchanged() {
    let result = MigrationProfileNaming.sourceLabel(for: "Moolah (Remote)")
    #expect(result == "Moolah (Remote)")
  }

  @Test
  func sourceLabel_alreadyHasRemoteWithDedupNumber_unchanged() {
    let result = MigrationProfileNaming.sourceLabel(for: "Moolah (Remote) 2")
    #expect(result == "Moolah (Remote) 2")
  }

  @Test
  func sourceLabel_hasOtherSuffix_appendsRemote() {
    let result = MigrationProfileNaming.sourceLabel(for: "Moolah (iCloud)")
    #expect(result == "Moolah (iCloud) (Remote)")
  }

  // MARK: - Target profile naming (iCloud suffix)

  @Test
  func targetLabel_plainName_appendsiCloud() {
    let result = MigrationProfileNaming.targetLabel(for: "Moolah")
    #expect(result == "Moolah (iCloud)")
  }

  @Test
  func targetLabel_hasRemoteSuffix_replacesWithiCloud() {
    let result = MigrationProfileNaming.targetLabel(for: "Moolah (Remote)")
    #expect(result == "Moolah (iCloud)")
  }

  @Test
  func targetLabel_alreadyHasiCloud_keepsiCloud() {
    let result = MigrationProfileNaming.targetLabel(for: "Moolah (iCloud)")
    #expect(result == "Moolah (iCloud)")
  }

  // MARK: - Unique name deduplication

  @Test
  func uniqueName_noConflict_returnsOriginal() {
    let result = MigrationProfileNaming.uniqueName("Moolah (iCloud)", among: ["Moolah (Remote)"])
    #expect(result == "Moolah (iCloud)")
  }

  @Test
  func uniqueName_oneConflict_appends2() {
    let result = MigrationProfileNaming.uniqueName(
      "Moolah (iCloud)", among: ["Moolah (iCloud)"])
    #expect(result == "Moolah (iCloud) 2")
  }

  @Test
  func uniqueName_twoConflicts_appends3() {
    let result = MigrationProfileNaming.uniqueName(
      "Moolah (iCloud)", among: ["Moolah (iCloud)", "Moolah (iCloud) 2"])
    #expect(result == "Moolah (iCloud) 3")
  }

  @Test
  func uniqueName_emptyExisting_returnsOriginal() {
    let result = MigrationProfileNaming.uniqueName("Moolah (iCloud)", among: [])
    #expect(result == "Moolah (iCloud)")
  }

  // MARK: - Combined: migratedLabels

  @Test
  func migratedLabels_plainName_noConflicts() {
    let (source, target) = MigrationProfileNaming.migratedLabels(
      sourceLabel: "Moolah", existingLabels: [])
    #expect(source == "Moolah (Remote)")
    #expect(target == "Moolah (iCloud)")
  }

  @Test
  func migratedLabels_plainName_targetConflict() {
    let (source, target) = MigrationProfileNaming.migratedLabels(
      sourceLabel: "Moolah", existingLabels: ["Moolah (iCloud)"])
    #expect(source == "Moolah (Remote)")
    #expect(target == "Moolah (iCloud) 2")
  }

  @Test
  func migratedLabels_remoteSource_replacesForTarget() {
    let (source, target) = MigrationProfileNaming.migratedLabels(
      sourceLabel: "Moolah (Remote)", existingLabels: [])
    #expect(source == "Moolah (Remote)")
    #expect(target == "Moolah (iCloud)")
  }

  @Test
  func migratedLabels_sourceRenameConflictsWithExisting() {
    // Source is "Moolah", would become "Moolah (Remote)" but that already exists
    let (source, target) = MigrationProfileNaming.migratedLabels(
      sourceLabel: "Moolah", existingLabels: ["Moolah (Remote)"])
    #expect(source == "Moolah (Remote) 2")
    #expect(target == "Moolah (iCloud)")
  }

  @Test
  func migratedLabels_bothConflict() {
    let (source, target) = MigrationProfileNaming.migratedLabels(
      sourceLabel: "Moolah", existingLabels: ["Moolah (Remote)", "Moolah (iCloud)"])
    #expect(source == "Moolah (Remote) 2")
    #expect(target == "Moolah (iCloud) 2")
  }
}
