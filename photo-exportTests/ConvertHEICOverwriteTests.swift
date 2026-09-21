import Foundation
import Photos
import Testing

@testable import Photo_Export

/// End-to-end coverage for the "Replace already-exported HEIC files" toggle
/// (companion to the issue #47 HEIC→JPEG conversion). Pins the four
/// load-bearing contracts of the overwrite flow:
///
/// 1. Stale `.done` HEIC variants are rewritten as JPEG and the old HEIC file
///    is deleted — but only after every required variant is satisfied.
/// 2. With the toggle off, existing HEIC exports are never touched.
/// 3. HEIC files that are no longer required under the current selection are
///    removed by a cleanup-only run (no re-export, no converter call).
/// 4. Live Photo paired `.MOV` files follow the still: they are rewritten so
///    the pair keeps sharing one natural stem instead of splitting into
///    ` (1)`-suffixed duplicates.
@MainActor
struct ConvertHEICOverwriteTests {

  // MARK: - Test harness

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeImageConverter, FakeFileSystem, ExportRecordStore
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let converter = FakeImageConverter()
    let fileSystem = FakeFileSystem()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("HEICOverwrite-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")
    let defaults = UserDefaults(
      suiteName: "test-HEICOverwrite-\(UUID().uuidString)")!

    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      assetResourceWriter: writer,
      imageConverter: converter,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return (manager, photoLib, dest, writer, converter, fileSystem, store)
  }

  /// Seeds the store with a `.done` record for `(assetId, variant)` and plants
  /// a real file at the placement's month directory so deletion assertions can
  /// observe the overwrite flow end to end.
  private func seedDoneVariant(
    _ store: ExportRecordStore,
    assetId: String,
    variant: ExportVariant,
    year: Int,
    month: Int,
    filename: String
  ) {
    store.markVariantExported(
      assetId: assetId, variant: variant, year: year, month: month,
      relPath: "\(year)/\(String(format: "%02d", month))/",
      filename: filename, exportedAt: Date())
  }

  private func monthDir(_ dest: FakeExportDestination, year: Int, month: Int) throws -> URL {
    try dest.urlForMonth(year: year, month: month, createIfNeeded: true)
  }

  private func plantFile(_ name: String, in dir: URL, contents: Data = Data([0x00])) {
    FileManager.default.createFile(
      atPath: dir.appendingPathComponent(name).path, contents: contents)
  }

  // MARK: - 1. Overwrite on: stale HEIC is rewritten as JPEG and deleted

  @Test func overwriteOnRewritesStaleHEICAsJPEGAndDeletesOldFile() async throws {
    let (manager, photoLib, dest, writer, converter, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.convertHEICToJPEG = true
    manager.convertHEICOverwriteExisting = true
    manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(
      id: "heic-asset", hasAdjustments: false, originalUTI: "public.heic")
    photoLib.assetsByYearMonth["2025-3"] = [asset]
    photoLib.resourcesByAssetId["heic-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
    ]

    // Pre-state: exported before the conversion toggle existed — the natural
    // stem holds a HEIC file, recorded `.done` under `.original`.
    let dir = try monthDir(dest, year: 2025, month: 3)
    plantFile("IMG_0001.HEIC", in: dir, contents: Data("old-heic".utf8))
    seedDoneVariant(store, assetId: "heic-asset", variant: .original, year: 2025, month: 3,
      filename: "IMG_0001.HEIC")

    manager.startExportMonth(year: 2025, month: 3)
    await manager.waitForQueueDrained()

    // The stale HEIC's widens `.edited`-requirement produced a JPEG rewrite.
    #expect(converter.convertCalls.count == 1,
      "Stale HEIC must be re-encoded as JPEG exactly once")
    let record = store.exportInfo(assetId: "heic-asset")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG")
    // The stale `.original` record is gone and so is its file.
    #expect(record?.variants[.original] == nil,
      "Stale HEIC variant record must be removed after the rewrite")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.HEIC").path),
      "The old HEIC file must be deleted from the destination")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.JPG").path),
      "The JPEG replacement must exist at the natural stem")
  }

  // MARK: - 2. Overwrite off: existing HEIC files are untouched (JPEG lands alongside)

  @Test func overwriteOffNeverTouchesExistingHEIC() async throws {
    let (manager, photoLib, dest, writer, converter, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.convertHEICToJPEG = true
    manager.convertHEICOverwriteExisting = false
    manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(
      id: "heic-asset", hasAdjustments: false, originalUTI: "public.heic")
    photoLib.assetsByYearMonth["2025-4"] = [asset]
    photoLib.resourcesByAssetId["heic-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
    ]

    let dir = try monthDir(dest, year: 2025, month: 4)
    plantFile("IMG_0001.HEIC", in: dir, contents: Data("old-heic".utf8))
    seedDoneVariant(store, assetId: "heic-asset", variant: .original, year: 2025, month: 4,
      filename: "IMG_0001.HEIC")

    manager.startExportMonth(year: 2025, month: 4)
    await manager.waitForQueueDrained()

    // Pre-overwrite issue-#47 behaviour: the conversion requirement widens
    // `.edited`, so a fresh JPEG is written alongside — but the stale HEIC
    // file and its record are never deleted.
    #expect(converter.convertCalls.count == 1,
      "Conversion requirement still applies to the new JPEG write")
    let record = store.exportInfo(assetId: "heic-asset")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001.HEIC",
      "Overwrite off must keep the stale HEIC record")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.HEIC").path),
      "Overwrite off must leave the existing HEIC file in place")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.JPG").path))
  }

  // MARK: - 3. Cleanup-only run: no longer required HEIC is removed

  @Test func cleanupOnlyRunRemovesStaleHEICWithoutReexport() async throws {
    let (manager, photoLib, dest, writer, converter, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.convertHEICToJPEG = true
    manager.convertHEICOverwriteExisting = true
    manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(
      id: "mixed-asset", hasAdjustments: false, originalUTI: "public.heic")
    photoLib.assetsByYearMonth["2025-5"] = [asset]
    photoLib.resourcesByAssetId["mixed-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
    ]

    // Pre-state: a partial overwrite already happened — the JPEG edit is done,
    // but the old natural-stem HEIC (and its record) remain.
    let dir = try monthDir(dest, year: 2025, month: 5)
    plantFile("IMG_0001.JPG", in: dir, contents: Data("jpeg".utf8))
    plantFile("IMG_0001.HEIC", in: dir, contents: Data("old-heic".utf8))
    seedDoneVariant(store, assetId: "mixed-asset", variant: .edited, year: 2025, month: 5,
      filename: "IMG_0001.JPG")
    seedDoneVariant(store, assetId: "mixed-asset", variant: .original, year: 2025, month: 5,
      filename: "IMG_0001.HEIC")

    manager.startExportMonth(year: 2025, month: 5)
    await manager.waitForQueueDrained()

    #expect(converter.convertCalls.isEmpty,
      "Cleanup-only run must not re-encode anything")
    #expect(writer.writeCalls.isEmpty,
      "Cleanup-only run must not rewrite any variant")
    let record = store.exportInfo(assetId: "mixed-asset")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.original] == nil,
      "The stale HEIC record must be dropped once its file is deleted")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.HEIC").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.JPG").path))
  }

  // MARK: - 4. editedWithOriginals: natural HEIC becomes _orig companion

  @Test func overwriteWithOriginalsMovesNaturalHEICIntoOrigCompanion() async throws {
    let (manager, photoLib, dest, writer, converter, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.convertHEICToJPEG = true
    manager.convertHEICOverwriteExisting = true
    manager.versionSelection = .editedWithOriginals

    let asset = TestAssetFactory.makeAsset(
      id: "orig-heic", hasAdjustments: false, originalUTI: "public.heic")
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId["orig-heic"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
    ]

    // Pre-state: exported with the conversion toggle off — one natural-stem
    // HEIC, no edit, no companion.
    let dir = try monthDir(dest, year: 2025, month: 6)
    plantFile("IMG_0001.HEIC", in: dir, contents: Data("old-heic".utf8))
    seedDoneVariant(store, assetId: "orig-heic", variant: .original, year: 2025, month: 6,
      filename: "IMG_0001.HEIC")

    manager.startExportMonth(year: 2025, month: 6)
    await manager.waitForQueueDrained()

    let record = store.exportInfo(assetId: "orig-heic")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001_orig.HEIC",
      "The original must keep its HEIC bytes but move into the _orig companion slot")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.HEIC").path),
      "The old natural-stem HEIC must be deleted")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001_orig.HEIC").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.JPG").path))
  }

  // MARK: - 5. Live Photo: paired .MOV follows the rewritten still

  @Test func overwriteRewritesLivePhotoPairAtNaturalStem() async throws {
    let (manager, photoLib, dest, writer, converter, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.convertHEICToJPEG = true
    manager.convertHEICOverwriteExisting = true
    manager.livePhotosPairedExport = true
    manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(
      id: "live-heic", hasAdjustments: false, originalUTI: "public.heic",
      isLivePhoto: true)
    photoLib.assetsByYearMonth["2025-7"] = [asset]
    photoLib.resourcesByAssetId["live-heic"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
      TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_0001.MOV"),
    ]

    // Pre-state: still-only HEIC + paired MOV at the natural stems (exported
    // with the conversion toggle off).
    let dir = try monthDir(dest, year: 2025, month: 7)
    plantFile("IMG_0001.HEIC", in: dir, contents: Data("old-heic".utf8))
    plantFile("IMG_0001.MOV", in: dir, contents: Data("old-motion".utf8))
    seedDoneVariant(store, assetId: "live-heic", variant: .original, year: 2025, month: 7,
      filename: "IMG_0001.HEIC")
    seedDoneVariant(store, assetId: "live-heic", variant: .originalPairedVideo,
      year: 2025, month: 7, filename: "IMG_0001.MOV")

    manager.startExportMonth(year: 2025, month: 7)
    await manager.waitForQueueDrained()

    let record = store.exportInfo(assetId: "live-heic")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG",
      "The rewritten still must land at the natural stem")
    #expect(record?.variants[.editedPairedVideo]?.status == .done)
    #expect(record?.variants[.editedPairedVideo]?.filename == "IMG_0001.MOV",
      "The rewritten motion must keep the natural stem, not a (1) suffix")
    #expect(record?.variants[.original] == nil)
    #expect(record?.variants[.originalPairedVideo] == nil)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.HEIC").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.JPG").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.MOV").path))
    #expect(writer.writeCalls.contains { $0.resource.type == .pairedVideo },
      "The paired motion must be rewritten after the old file was removed")
  }

  // MARK: - 6. Conversion failure keeps the stale HEIC intact

  @Test func conversionFailureKeepsStaleHEICIntact() async throws {
    let (manager, photoLib, dest, writer, converter, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.convertHEICToJPEG = true
    manager.convertHEICOverwriteExisting = true
    manager.versionSelection = .edited
    converter.convertError = NSError(
      domain: "test", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "converter boom"])

    let asset = TestAssetFactory.makeAsset(
      id: "failing-heic", hasAdjustments: false, originalUTI: "public.heic")
    photoLib.assetsByYearMonth["2025-8"] = [asset]
    photoLib.resourcesByAssetId["failing-heic"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
    ]

    let dir = try monthDir(dest, year: 2025, month: 8)
    plantFile("IMG_0001.HEIC", in: dir, contents: Data("old-heic".utf8))
    seedDoneVariant(store, assetId: "failing-heic", variant: .original, year: 2025, month: 8,
      filename: "IMG_0001.HEIC")

    manager.startExportMonth(year: 2025, month: 8)
    await manager.waitForQueueDrained()

    let record = store.exportInfo(assetId: "failing-heic")
    #expect(record?.variants[.edited]?.status == .failed)
    // Rule C: the stale HEIC is only deleted once every required variant is
    // satisfied. A failed conversion must leave the old bytes on disk — even
    // though the issue #22 `_orig` fallback re-homes the `.original` record to
    // the companion slot in the same run (the original bytes are preserved
    // there, so nothing is lost).
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001_orig.HEIC")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_0001.HEIC").path),
      "The stale HEIC file must survive a failed conversion")
    #expect(FileManager.default.fileExists(
      atPath: dir.appendingPathComponent("IMG_0001_orig.HEIC").path),
      "The fallback re-homes the original bytes to the companion slot")
  }

  // MARK: - 7. Pure policy matrix

  /// `_orig` companions, paired videos, non-HEIC files, and toggle-off states
  /// are never stale; a natural-stem `.heic`/`.heif` done-variant is.
  @Test func staleHEICPolicyMatrix() {
    func record(_ filename: String?) -> ExportVariantRecord {
      ExportVariantRecord(
        filename: filename, status: .done, exportDate: Date(), lastError: nil)
    }

    // Off toggles: nothing is ever stale.
    #expect(
      ExportCompletionPolicy.staleHEICVariants(
        variants: [.original: record("IMG_0001.HEIC")],
        convertHEICToJPEG: false, overwriteExisting: true).isEmpty)
    #expect(
      ExportCompletionPolicy.staleHEICVariants(
        variants: [.original: record("IMG_0001.HEIC")],
        convertHEICToJPEG: true, overwriteExisting: false).isEmpty)

    // Natural-stem HEIC/HEIF done-variants are stale.
    let stale = ExportCompletionPolicy.staleHEICVariants(
      variants: [
        .original: record("IMG_0001.HEIC"),
        .edited: record("IMG_0002.heif"),
      ],
      convertHEICToJPEG: true, overwriteExisting: true)
    #expect(Set(stale.keys) == [.original, .edited])

    // Companion form, paired videos, JPEGs, failed and in-progress records
    // are exempt.
    let exempt = ExportCompletionPolicy.staleHEICVariants(
      variants: [
        .original: record("IMG_0001_orig.HEIC"),
        .originalPairedVideo: record("IMG_0001.MOV"),
        .edited: record("IMG_0002.JPG"),
        .editedPairedVideo: record("IMG_0002.MOV"),
      ],
      convertHEICToJPEG: true, overwriteExisting: true)
    #expect(exempt.isEmpty)

    // Non-done statuses never count as stale.
    var failed = record("IMG_0003.HEIC")
    failed.status = .failed
    #expect(
      ExportCompletionPolicy.staleHEICVariants(
        variants: [.original: failed],
        convertHEICToJPEG: true, overwriteExisting: true).isEmpty)

    // Filename predicate agrees with the variant scan.
    #expect(ExportCompletionPolicy.isStaleHEICFilename("IMG_0001.HEIC"))
    #expect(ExportCompletionPolicy.isStaleHEICFilename("IMG_0001.heif"))
    #expect(!ExportCompletionPolicy.isStaleHEICFilename("IMG_0001_orig.HEIC"))
    #expect(!ExportCompletionPolicy.isStaleHEICFilename("IMG_0001.JPG"))
    #expect(!ExportCompletionPolicy.isStaleHEICFilename("IMG_0001.MOV"))
    #expect(!ExportCompletionPolicy.isStaleHEICFilename("IMG_0001_orig (1).heic"))
  }
}
