import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for the missing-file reconcile that runs before each export run's
/// planning step (`ExportManager.reconcileMissingFilesForScope`): a `.done`
/// record whose backing file was deleted from the destination by hand is
/// pruned, so the run re-queues the asset and re-creates the file instead of
/// reporting "already exported" forever.
///
/// Scoping contract pinned here: only the run's own export scope is reconciled.
/// A month run never touches another month's records, a year run never touches
/// another year's, and a folder run never touches albums outside its subtree —
/// deliberately-deleted files in other scopes are not resurrected.
@MainActor
struct MissingFileReexportTests {

  // MARK: - Harness (mirrors ExportManagerRunExportTests)

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let store: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() {
      manager.cancelAndClear()
      store.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
      UserDefaults().removePersistentDomain(forName: userDefaultsSuite)
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("MissingFileReexport-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-MissingFileReexport-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      store: store, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  private func seedTimelineAsset(
    _ harness: Harness, id: String, year: Int, month: Int, filename: String
  ) -> AssetDescriptor {
    let asset = TestAssetFactory.makeAsset(
      id: id, creationDate: makeDate(year, month, 15))
    harness.photoLib.assetsByYearMonth["\(year)-\(month)"] = [asset]
    harness.photoLib.resourcesByAssetId[id] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: filename)
    ]
    return asset
  }

  private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var components = DateComponents()
    components.year = y
    components.month = m
    components.day = d
    return Calendar.current.date(from: components) ?? Date()
  }

  /// Deletes the file at `root/relPath/filename` if present.
  private func deleteFile(root: URL, relPath: String, filename: String) {
    let url = root.appendingPathComponent(relPath, isDirectory: true)
      .appendingPathComponent(filename)
    try? FileManager.default.removeItem(at: url)
  }

  private func waitUntil(
    timeout: TimeInterval = 10, _ condition: @autoclosure () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  // MARK: - Timeline month scope

  /// The headline bug: export a month, the user deletes the file by hand, a
  /// re-run of the same month must re-create it (previously the `.done`
  /// record kept every later run reporting "already exported").
  @Test func deletedTimelineFileIsRecreatedOnNextMonthExport() async {
    let h = makeHarness()
    defer { h.cleanup() }

    seedTimelineAsset(h, id: "march-1", year: 2026, month: 3, filename: "IMG_0303.HEIC")
    h.manager.startExportMonth(year: 2026, month: 3)
    await h.manager.waitForQueueDrained()

    let fileURL = h.dest.rootURL.appendingPathComponent("2026/03", isDirectory: true)
      .appendingPathComponent("IMG_0303.HEIC")
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(h.writer.writeCalls.count == 1)

    // The user deletes the file from the destination; the record still says `.done`.
    try? FileManager.default.removeItem(at: fileURL)

    h.manager.startExportMonth(year: 2026, month: 3)
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.count == 2, "the deleted file must be re-exported")
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    let record = h.store.exportInfo(assetId: "march-1")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0303.HEIC")
    #expect(h.manager.emptyRunMessage == nil, "run had real work — no empty-run banner")
  }

  /// Scoping contract: a month run only reconciles its own month. A file the
  /// user deleted in June stays deleted (and its record stays stale) when the
  /// user re-exports March.
  @Test func monthRunDoesNotResurrectFilesDeletedInOtherMonths() async {
    let h = makeHarness()
    defer { h.cleanup() }

    seedTimelineAsset(h, id: "march-1", year: 2026, month: 3, filename: "IMG_0303.HEIC")
    seedTimelineAsset(h, id: "june-1", year: 2026, month: 6, filename: "IMG_0606.HEIC")
    h.manager.startExportMonth(year: 2026, month: 3)
    await h.manager.waitForQueueDrained()
    h.manager.startExportMonth(year: 2026, month: 6)
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.count == 2)

    deleteFile(root: h.dest.rootURL, relPath: "2026/06/", filename: "IMG_0606.HEIC")

    h.manager.startExportMonth(year: 2026, month: 3)
    await h.manager.waitForQueueDrained()
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(
      h.manager.emptyRunMessage == "This month is already exported.",
      "March is untouched — the run must not fan out to other months")
    #expect(h.writer.writeCalls.count == 2, "no write outside the run's scope")
    let juneRecord = h.store.exportInfo(assetId: "june-1")
    #expect(juneRecord?.variants[.original]?.status == .done, "June's record is not reconciled by a March run")
    #expect(
      !FileManager.default.fileExists(
        atPath: h.dest.rootURL.appendingPathComponent("2026/06/IMG_0606.HEIC").path),
      "June's deleted file is not resurrected by a March run")
  }

  // MARK: - Timeline year scope

  /// A year run reconciles every recorded month within the year: files the
  /// user deleted across several months are all re-created in one run.
  @Test func deletedFilesAcrossMonthsAreRecreatedOnNextYearExport() async {
    let h = makeHarness()
    defer { h.cleanup() }

    seedTimelineAsset(h, id: "march-1", year: 2025, month: 3, filename: "IMG_0303.HEIC")
    seedTimelineAsset(h, id: "august-1", year: 2025, month: 8, filename: "IMG_0808.HEIC")
    h.manager.startExportYear(year: 2025)
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.count == 2)

    deleteFile(root: h.dest.rootURL, relPath: "2025/03/", filename: "IMG_0303.HEIC")
    deleteFile(root: h.dest.rootURL, relPath: "2025/08/", filename: "IMG_0808.HEIC")

    h.manager.startExportYear(year: 2025)
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.count == 4, "both deleted files re-exported by the year run")
    #expect(
      FileManager.default.fileExists(
        atPath: h.dest.rootURL.appendingPathComponent("2025/03/IMG_0303.HEIC").path))
    #expect(
      FileManager.default.fileExists(
        atPath: h.dest.rootURL.appendingPathComponent("2025/08/IMG_0808.HEIC").path))
  }

  /// Scoping contract at year granularity: a 2025 year run never probes
  /// 2026's records, so a file the user deleted from the 2026 folder stays
  /// deleted (and its record stays stale) until the 2026 scope is exported.
  @Test func yearRunDoesNotResurrectFilesDeletedInOtherYears() async {
    let h = makeHarness()
    defer { h.cleanup() }

    seedTimelineAsset(h, id: "y25-1", year: 2025, month: 3, filename: "IMG_2503.HEIC")
    seedTimelineAsset(h, id: "y26-1", year: 2026, month: 3, filename: "IMG_2603.HEIC")
    h.manager.startExportYear(year: 2025)
    await h.manager.waitForQueueDrained()
    h.manager.startExportYear(year: 2026)
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.count == 2)

    deleteFile(root: h.dest.rootURL, relPath: "2026/03/", filename: "IMG_2603.HEIC")

    h.manager.startExportYear(year: 2025)
    await h.manager.waitForQueueDrained()
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(
      h.manager.emptyRunMessage == "This year is already exported.")
    #expect(h.writer.writeCalls.count == 2, "no write outside the run's year")
    let staleRecord = h.store.exportInfo(assetId: "y26-1")
    #expect(staleRecord?.variants[.original]?.status == .done, "2026's record is not reconciled by a 2025 run")
    #expect(
      !FileManager.default.fileExists(
        atPath: h.dest.rootURL.appendingPathComponent("2026/03/IMG_2603.HEIC").path))
  }

  // MARK: - Collection scope (Favorites)

  @Test func deletedFavoritesFileIsRecreatedOnNextFavoritesRun() async {
    let h = makeHarness()
    defer { h.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "fav-1")
    h.photoLib.favoritesAssets = [asset]
    h.photoLib.resourcesByAssetId["fav-1"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_FAV.HEIC")
    ]

    h.manager.startExportFavorites()
    await h.manager.waitForQueueDrained()
    let fileURL = h.dest.rootURL.appendingPathComponent(
      "Collections/Favorites", isDirectory: true)
      .appendingPathComponent("IMG_FAV.HEIC")
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(h.writer.writeCalls.count == 1)

    try? FileManager.default.removeItem(at: fileURL)

    h.manager.startExportFavorites()
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.count == 2)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    let placement = h.collectionStore.placements(matching: .favorites).first
    #expect(placement != nil)
  }

  // MARK: - Collection scope (nested album tree)

  /// Builds a nested album tree under one root folder:
  ///
  ///     folder "Root"
  ///       ├─ album "Direct"                → Collections/Albums/Direct/
  ///       └─ folder "Travel"
  ///            ├─ album "Trip"             → Collections/Albums/Travel/Trip/
  ///            └─ album "Beach"            → Collections/Albums/Travel/Beach/
  private func seedNestedAlbumTree(_ h: Harness) {
    let direct = PhotoCollectionDescriptor(
      id: "album:direct", localIdentifier: "direct", title: "Direct",
      kind: .album, pathComponents: [], children: [])
    let trip = PhotoCollectionDescriptor(
      id: "album:trip", localIdentifier: "trip", title: "Trip",
      kind: .album, pathComponents: ["Travel"], children: [])
    let beach = PhotoCollectionDescriptor(
      id: "album:beach", localIdentifier: "beach", title: "Beach",
      kind: .album, pathComponents: ["Travel"], children: [])
    let travel = PhotoCollectionDescriptor(
      id: "folder:travel", localIdentifier: "Travel", title: "Travel",
      kind: .folder, pathComponents: [], children: [trip, beach])
    let root = PhotoCollectionDescriptor(
      id: "folder:root", localIdentifier: "Root", title: "Root",
      kind: .folder, pathComponents: [], children: [direct, travel])
    h.photoLib.collectionTree = [root]

    seedAlbumAssets(h, localId: "direct", ids: ["d1"], filename: "DIRECT.HEIC")
    seedAlbumAssets(h, localId: "trip", ids: ["t1", "t2"], filename: "TRIP1.HEIC")
    seedAlbumAssets(h, localId: "beach", ids: ["b1"], filename: "BEACH.HEIC")
  }

  private func seedAlbumAssets(
    _ h: Harness, localId: String, ids: [String], filename: String
  ) {
    h.photoLib.assetsByAlbumLocalId[localId] = ids.map { id in
      let asset = TestAssetFactory.makeAsset(id: id)
      h.photoLib.resourcesByAssetId[id] = [
        TestAssetFactory.makeResource(type: .photo, originalFilename: "\(id)-\(filename)")
      ]
      return asset
    }
  }

  private func albumFileURL(_ root: URL, path: String, filename: String) -> URL {
    root.appendingPathComponent("Collections/Albums/\(path)", isDirectory: true)
      .appendingPathComponent(filename)
  }

  /// A folder run reconciles every descendant album at its nested on-disk
  /// path: files the user deleted from a nested album folder are re-created,
  /// while files still present in sibling albums are not rewritten.
  @Test func folderExportRecreatesDeletedFilesInNestedAlbums() async {
    let h = makeHarness()
    defer { h.cleanup() }
    seedNestedAlbumTree(h)

    h.manager.startExportFolder(folderId: "Root")
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.count == 4, "two Trip, one Beach, one Direct")

    // All four files land at their nested placement paths.
    #expect(FileManager.default.fileExists(
      atPath: albumFileURL(h.dest.rootURL, path: "Travel/Trip/", filename: "t1-TRIP1.HEIC").path))
    #expect(FileManager.default.fileExists(
      atPath: albumFileURL(h.dest.rootURL, path: "Travel/Trip/", filename: "t2-TRIP1.HEIC").path))
    #expect(FileManager.default.fileExists(
      atPath: albumFileURL(h.dest.rootURL, path: "Travel/Beach/", filename: "b1-BEACH.HEIC").path))
    #expect(FileManager.default.fileExists(
      atPath: albumFileURL(h.dest.rootURL, path: "Direct/", filename: "d1-DIRECT.HEIC").path))

    // The user deletes one file deep inside the nested tree and one at the
    // top level; the Beach and Trip-2 files stay intact.
    deleteFile(
      root: h.dest.rootURL, relPath: "Collections/Albums/Travel/Trip/", filename: "t1-TRIP1.HEIC")
    deleteFile(root: h.dest.rootURL, relPath: "Collections/Albums/Direct/", filename: "d1-DIRECT.HEIC")

    h.manager.startExportFolder(folderId: "Root")
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.count == 6, "only the two deleted files are re-exported")
    let writtenIds = h.writer.writeCalls.map(\.assetId)
    #expect(
      writtenIds.filter { $0 == "t1" }.count == 2, "deleted nested-album file re-created")
    #expect(
      writtenIds.filter { $0 == "d1" }.count == 2, "deleted top-level-album file re-created")
    #expect(
      writtenIds.filter { $0 == "b1" }.count == 1, "intact Beach file must not be rewritten")
    #expect(
      writtenIds.filter { $0 == "t2" }.count == 1, "intact Trip-2 file must not be rewritten")

    #expect(FileManager.default.fileExists(
      atPath: albumFileURL(h.dest.rootURL, path: "Travel/Trip/", filename: "t1-TRIP1.HEIC").path))
    #expect(FileManager.default.fileExists(
      atPath: albumFileURL(h.dest.rootURL, path: "Direct/", filename: "d1-DIRECT.HEIC").path))
  }

  /// Scoping contract inside the tree: exporting the nested subfolder only
  /// reconciles albums under it — a file deleted from a sibling album above
  /// the subtree stays deleted and its record stays stale.
  @Test func nestedSubfolderExportDoesNotResurrectFilesOutsideItsSubtree() async {
    let h = makeHarness()
    defer { h.cleanup() }
    seedNestedAlbumTree(h)

    h.manager.startExportFolder(folderId: "Root")
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.count == 4)

    // The user deletes the Direct album's file — inside Root's subtree but
    // NOT inside the Travel subfolder the next run targets.
    deleteFile(root: h.dest.rootURL, relPath: "Collections/Albums/Direct/", filename: "d1-DIRECT.HEIC")

    h.manager.startExportFolder(folderId: "Travel")
    await h.manager.waitForQueueDrained()
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(
      h.manager.emptyRunMessage == "All albums in this folder are already exported.",
      "Trip and Beach are untouched — the Travel run must not fan out above itself")
    #expect(h.writer.writeCalls.count == 4, "no write outside the run's subtree")
    let directPlacement = h.collectionStore.placements.values.first {
      $0.collectionLocalIdentifier == "direct"
    }
    let directRecord = directPlacement.map {
      h.collectionStore.exportInfo(assetId: "d1", placement: $0)
    }
    #expect(directRecord??.variants[.original]?.status == .done, "Direct's records survive a Travel-scoped run")
    #expect(
      !FileManager.default.fileExists(
        atPath: albumFileURL(h.dest.rootURL, path: "Direct/", filename: "d1-DIRECT.HEIC").path))
  }
}
