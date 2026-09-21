import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 3.3 of the collections-export plan adds the reuse-source copy path: when
/// `(asset, variant)` is already exported under another placement, the writer copies
/// the existing file rather than re-fetching from PhotoKit. On APFS the copy is a CoW
/// clone (no extra disk usage); on non-APFS it's a real copy.
///
/// These tests exercise the lookup-and-copy path through the real `ExportManager` flow,
/// verifying that the `FileManager.copyItem` call lands and the PhotoKit writer is not
/// invoked. APFS-clone byte-delta tests are deferred to manual testing per the plan
/// (`free-space delta on a known-size source file` requires real volume APIs).
@MainActor
struct ReuseSourceCopyPathTests {

  // MARK: - Fixtures

  private func makeManager() throws -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeFileSystem, ExportRecordStore, CollectionExportRecordStore, URL
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReuseSource-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let defaults = UserDefaults(
      suiteName: "test-ReuseCopy-\(UUID().uuidString)")!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return (manager, photoLib, dest, writer, fileSystem, timelineStore, collectionStore, storeRoot)
  }

  private func makeAsset(id: String) -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: false
    )
  }

  // MARK: - Reuse from timeline → favorites

  /// An asset already exported to timeline `2025/02/IMG.HEIC` then re-exported under
  /// favorites copies the existing file via `FileManager.copyItem`; the PhotoKit
  /// writer is not invoked.
  @Test func favoritesReusesTimelineFile() async throws {
    let (
      manager, photoLib, dest, writer, fileSystem, _, _, storeRoot
    ) = try makeManager()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    let asset = makeAsset(id: "shared-asset")
    photoLib.assetsByYearMonth["2025-2"] = [asset]
    photoLib.favoritesAssets = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]
    // Pre-stage timeline export: a real file at the destination + a .done record.
    let timelineDir = try dest.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    let timelineFile = timelineDir.appendingPathComponent("IMG.HEIC")
    try Data("photo bytes".utf8).write(to: timelineFile)
    manager.exportRecordStore.markVariantExported(
      assetId: asset.id, variant: .original, year: 2025, month: 2, relPath: "2025/02/",
      filename: "IMG.HEIC", exportedAt: Date())

    // Now export favorites. The pipeline should copy from the timeline file rather
    // than calling the asset resource writer.
    let writeCallsBefore = writer.writeCalls.count
    manager.startExportFavorites()
    await manager.waitForQueueDrained()

    #expect(writer.writeCalls.count == writeCallsBefore)  // PhotoKit writer not invoked
    let copyCalls = fileSystem.copyCalls
    #expect(copyCalls.count == 1)
    #expect(copyCalls.first?.from.lastPathComponent == "IMG.HEIC")

    // Verify the favorites file actually landed.
    let favoritesDir = try dest.urlForRelativeDirectory("Collections/Favorites/", createIfNeeded: false)
    let favoritesFile = favoritesDir.appendingPathComponent("IMG.HEIC")
    #expect(FileManager.default.fileExists(atPath: favoritesFile.path))
  }

  // MARK: - Reuse from favorites → timeline

  @Test func timelineReusesFavoritesFileForSameAsset() async throws {
    let (
      manager, photoLib, dest, writer, fileSystem, _, _, storeRoot
    ) = try makeManager()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    let asset = makeAsset(id: "asset-1")
    photoLib.assetsByYearMonth["2025-3"] = [asset]
    photoLib.favoritesAssets = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]

    // Pre-stage favorites export: real file + collection-store .done record.
    let favoritesDir = try dest.urlForRelativeDirectory(
      "Collections/Favorites/", createIfNeeded: true)
    let favoritesFile = favoritesDir.appendingPathComponent("IMG.HEIC")
    try Data("favorited bytes".utf8).write(to: favoritesFile)
    let favoritesPlacement = ExportPlacement.favorites()
    manager.collectionExportRecordStore.upsertPlacement(favoritesPlacement)
    manager.collectionExportRecordStore.markVariantExported(
      assetId: asset.id, placement: favoritesPlacement, variant: .original,
      filename: "IMG.HEIC", exportedAt: Date())

    let writeCallsBefore = writer.writeCalls.count
    manager.startExportMonth(year: 2025, month: 3)
    await manager.waitForQueueDrained()

    // Reuse-source lookup found favorites first; PhotoKit not invoked.
    #expect(writer.writeCalls.count == writeCallsBefore)
    #expect(fileSystem.copyCalls.count == 1)

    // Timeline file landed.
    let timelineDir = try dest.urlForRelativeDirectory("2025/03/", createIfNeeded: false)
    #expect(FileManager.default.fileExists(atPath: timelineDir.appendingPathComponent("IMG.HEIC").path))
  }

  // MARK: - Source missing → PhotoKit fallback

  /// Plan §"Reuse-Source Copy Path → Source-side error": stale `.done` record points at
  /// a file that doesn't exist (user deleted it in Finder). The reuse copy fails;
  /// pipeline falls back to the PhotoKit re-export.
  @Test func missingReuseSourceFallsBackToPhotoKit() async throws {
    let (
      manager, photoLib, dest, writer, fileSystem, _, _, storeRoot
    ) = try makeManager()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    let asset = makeAsset(id: "ghost-asset")
    photoLib.favoritesAssets = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]

    // Mark the asset as `.done` in the timeline store but DO NOT write the actual file.
    manager.exportRecordStore.markVariantExported(
      assetId: asset.id, variant: .original, year: 2025, month: 4, relPath: "2025/04/",
      filename: "IMG.HEIC", exportedAt: Date())

    let writeCallsBefore = writer.writeCalls.count
    manager.startExportFavorites()
    await manager.waitForQueueDrained()

    // The copy attempt failed (source missing), so PhotoKit was called as fallback.
    #expect(writer.writeCalls.count == writeCallsBefore + 1)
    // copyCalls still records the attempted copy.
    #expect(fileSystem.copyCalls.count == 1)
  }

  // MARK: - No reuse source → straight PhotoKit

  @Test func noReuseSourceUsesPhotoKitDirectly() async throws {
    let (
      manager, photoLib, dest, writer, fileSystem, _, _, storeRoot
    ) = try makeManager()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    let asset = makeAsset(id: "fresh")
    photoLib.assetsByYearMonth["2025-5"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]

    let writeCallsBefore = writer.writeCalls.count
    manager.startExportMonth(year: 2025, month: 5)
    await manager.waitForQueueDrained()

    #expect(writer.writeCalls.count == writeCallsBefore + 1)
    #expect(fileSystem.copyCalls.isEmpty)
  }

  // MARK: - Freshness gate (stale reuse source → PhotoKit)

  /// User-reported regression: with "Replace updated files" on, a re-export
  /// triggered by an edit change cloned the *previous* content from another
  /// placement's `.done` record (the reuse path had no freshness check), so
  /// the destination never saw the new bytes — the stale content then
  /// circulated between placements with fresh `exportDate`s on every record.
  /// A source recorded before the asset's current modification date must be
  /// rejected; the PhotoKit writer fetches the current bytes instead.
  @Test func staleReuseSourceIsRejectedInFavorOfPhotoKit() async throws {
    let (
      manager, photoLib, dest, writer, fileSystem, _, _, storeRoot
    ) = try makeManager()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    // Favorites export written at T0 with the *old* edit's bytes.
    let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let favoritesPlacement = ExportPlacement.favorites()
    manager.collectionExportRecordStore.upsertPlacement(favoritesPlacement)
    let favoritesDir = try dest.urlForRelativeDirectory(
      "Collections/Favorites/", createIfNeeded: true)
    let favoritesFile = favoritesDir.appendingPathComponent("IMG.jpg")
    try Data("stale bytes".utf8).write(to: favoritesFile)
    manager.collectionExportRecordStore.markVariantExported(
      assetId: "re-edited", placement: favoritesPlacement, variant: .edited,
      filename: "IMG.jpg", exportedAt: exportedAt)

    // The user re-edited the photo in Photos after T0; the descriptor's
    // modification date now postdates the favorites record.
    let asset = AssetDescriptor(
      id: "re-edited", creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
      hasAdjustments: true, modificationDate: exportedAt.addingTimeInterval(60))
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .fullSizePhoto, originalFilename: "IMG.jpg")
    ]

    manager.startExportMonth(year: 2025, month: 6)
    await manager.waitForQueueDrained()

    // The stale favorites source was rejected → PhotoKit re-export ran.
    #expect(writer.writeCalls.count == 1)
    #expect(fileSystem.copyCalls.isEmpty, "got \(fileSystem.copyCalls)")

    // The month file holds the fresh bytes, not the cloned stale ones.
    let monthFile = dest.rootURL
      .appendingPathComponent("2025/06/", isDirectory: true)
      .appendingPathComponent("IMG.jpg")
    #expect(
      (try? Data(contentsOf: monthFile)) == Data("fake-content".utf8),
      "the month export must fetch the current edit from PhotoKit, not clone a stale placement file"
    )
  }

  /// A reuse source whose record is at least as new as the asset's
  /// modification date is still preferred over a PhotoKit fetch — the gate
  /// only rejects stale sources.
  @Test func freshReuseSourceIsStillPreferred() async throws {
    let (
      manager, photoLib, dest, writer, fileSystem, _, _, storeRoot
    ) = try makeManager()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let favoritesPlacement = ExportPlacement.favorites()
    manager.collectionExportRecordStore.upsertPlacement(favoritesPlacement)
    let favoritesDir = try dest.urlForRelativeDirectory(
      "Collections/Favorites/", createIfNeeded: true)
    try Data("current bytes".utf8).write(
      to: favoritesDir.appendingPathComponent("IMG.HEIC"))
    manager.collectionExportRecordStore.markVariantExported(
      assetId: "shared-2", placement: favoritesPlacement, variant: .original,
      filename: "IMG.HEIC", exportedAt: exportedAt)

    // modificationDate == exportDate: the source is up to date for this
    // asset, so cloning it is correct and cheap.
    let asset = AssetDescriptor(
      id: "shared-2", creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
      hasAdjustments: false, modificationDate: exportedAt)
    photoLib.assetsByYearMonth["2025-7"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]

    let writeCallsBefore = writer.writeCalls.count
    manager.startExportMonth(year: 2025, month: 7)
    await manager.waitForQueueDrained()

    #expect(writer.writeCalls.count == writeCallsBefore)
    #expect(fileSystem.copyCalls.count == 1)
    let timelineFile = dest.rootURL
      .appendingPathComponent("2025/07/", isDirectory: true)
      .appendingPathComponent("IMG.HEIC")
    #expect(
      (try? Data(contentsOf: timelineFile)) == Data("current bytes".utf8))
  }
}
