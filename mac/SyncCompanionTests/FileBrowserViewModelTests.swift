import XCTest
@testable import SyncCompanion

final class FileBrowserViewModelTests: XCTestCase {

    // MARK: - formatBytes (static)

    func testFormatBytesZero()        { XCTAssertEqual(FileBrowserViewModel.formatBytes(0), "0 B") }
    func testFormatBytesBytes()       { XCTAssertEqual(FileBrowserViewModel.formatBytes(999), "999 B") }
    func testFormatBytesKilobytes()   { XCTAssertEqual(FileBrowserViewModel.formatBytes(2048), "2.0 KB") }
    func testFormatBytesMegabytes()   { XCTAssertEqual(FileBrowserViewModel.formatBytes(3_145_728), "3.0 MB") }
    func testFormatBytesGigabytes()   { XCTAssertEqual(FileBrowserViewModel.formatBytes(2_147_483_648), "2.00 GB") }
    func testFormatBytesNegative()    { XCTAssertEqual(FileBrowserViewModel.formatBytes(-1), "-1 B") }

    // MARK: - BatchSummaryItem

    func testBatchSummaryItemEquality() {
        let a = BatchSummaryItem(category: "Photos", count: 3, bytes: 1024)
        let b = BatchSummaryItem(category: "Photos", count: 3, bytes: 1024)
        XCTAssertEqual(a, b)
    }

    func testBatchSummaryItemInequality() {
        let a = BatchSummaryItem(category: "Photos", count: 3, bytes: 1024)
        let b = BatchSummaryItem(category: "Videos", count: 1, bytes: 2048)
        XCTAssertNotEqual(a, b)
    }

    func testBatchSummaryItemDifferentCounts() {
        let a = BatchSummaryItem(category: "Photos", count: 1, bytes: 1024)
        let b = BatchSummaryItem(category: "Photos", count: 2, bytes: 1024)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - TransferJob struct

    func testTransferJobDefaultValues() {
        let job = TransferJob(kind: .download, name: "file.jpg", sourceURL: nil,
                             remotePath: "/file.jpg", destinationURL: nil,
                             progress: 0, state: .queued, error: nil)
        XCTAssertFalse(job.isFolder)
        XCTAssertEqual(job.transferredBytes, 0)
        XCTAssertEqual(job.completedFiles, 0)
        XCTAssertNil(job.startTime)
        XCTAssertNil(job.smoothedBytesPerSecond)
        XCTAssertTrue(job.recentSamples.isEmpty)
    }

    func testTransferJobEquality() {
        let j1 = TransferJob(kind: .upload, name: "a.zip", sourceURL: nil,
                             remotePath: "/a.zip", destinationURL: nil,
                             progress: 0.5, state: .running, error: nil)
        let j2 = TransferJob(kind: .upload, name: "a.zip", sourceURL: nil,
                             remotePath: "/a.zip", destinationURL: nil,
                             progress: 0.5, state: .running, error: nil)
        // Two separate jobs are never equal because id = UUID()
        XCTAssertNotEqual(j1, j2)
    }

    // MARK: - TransferState rawValues

    func testTransferStateRawValues() {
        XCTAssertEqual(TransferState.queued.rawValue, "Queued")
        XCTAssertEqual(TransferState.running.rawValue, "Running")
        XCTAssertEqual(TransferState.complete.rawValue, "Complete")
        XCTAssertEqual(TransferState.failed.rawValue, "Failed")
        XCTAssertEqual(TransferState.cancelled.rawValue, "Cancelled")
    }

    func testTransferKindRawValues() {
        XCTAssertEqual(TransferKind.upload.rawValue, "Upload")
        XCTAssertEqual(TransferKind.download.rawValue, "Download")
    }

    // MARK: - TransferSummary

    func testTransferSummaryEquality() {
        let s1 = TransferSummary(completedFiles: 5, skippedFiles: 1, failedFiles: 0, transferredBytes: 1024, destinationURL: nil)
        let s2 = TransferSummary(completedFiles: 5, skippedFiles: 1, failedFiles: 0, transferredBytes: 1024, destinationURL: nil)
        XCTAssertEqual(s1, s2)
    }

    // MARK: - WebDavItem helpers

    func testWebDavItemSfSymbolFolder() {
        let item = WebDavItem(name: "Folder", path: "/Folder", isDirectory: true, size: 0, modified: nil)
        XCTAssertEqual(item.sfSymbol, "folder.fill")
    }

    func testWebDavItemSfSymbolJpeg() {
        let item = WebDavItem(name: "photo.jpg", path: "/photo.jpg", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.sfSymbol, "photo")
    }

    func testWebDavItemSfSymbolMp4() {
        let item = WebDavItem(name: "clip.mp4", path: "/clip.mp4", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.sfSymbol, "film")
    }

    func testWebDavItemSfSymbolMp3() {
        let item = WebDavItem(name: "song.mp3", path: "/song.mp3", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.sfSymbol, "music.note")
    }

    func testWebDavItemSfSymbolPdf() {
        let item = WebDavItem(name: "doc.pdf", path: "/doc.pdf", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.sfSymbol, "doc.richtext")
    }

    func testWebDavItemSfSymbolZip() {
        let item = WebDavItem(name: "archive.zip", path: "/archive.zip", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.sfSymbol, "archivebox")
    }

    func testWebDavItemSfSymbolUnknown() {
        let item = WebDavItem(name: "data.bin", path: "/data.bin", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.sfSymbol, "doc")
    }

    func testWebDavItemIsPreviewableImage() {
        let jpg  = WebDavItem(name: "a.jpg",  path: "/a.jpg",  isDirectory: false, size: 0, modified: nil)
        let heic = WebDavItem(name: "a.heic", path: "/a.heic", isDirectory: false, size: 0, modified: nil)
        let dir  = WebDavItem(name: "dir",    path: "/dir",    isDirectory: true,  size: 0, modified: nil)
        XCTAssertTrue(jpg.isPreviewableImage)
        XCTAssertTrue(heic.isPreviewableImage)
        XCTAssertFalse(dir.isPreviewableImage)
    }

    func testWebDavItemIsPreviewableVideo() {
        let mp4 = WebDavItem(name: "v.mp4", path: "/v.mp4", isDirectory: false, size: 0, modified: nil)
        let mov = WebDavItem(name: "v.mov", path: "/v.mov", isDirectory: false, size: 0, modified: nil)
        let txt = WebDavItem(name: "t.txt", path: "/t.txt", isDirectory: false, size: 0, modified: nil)
        XCTAssertTrue(mp4.isPreviewableVideo)
        XCTAssertTrue(mov.isPreviewableVideo)
        XCTAssertFalse(txt.isPreviewableVideo)
    }

    func testWebDavItemIsPreviewablePDF() {
        let pdf = WebDavItem(name: "d.pdf", path: "/d.pdf", isDirectory: false, size: 0, modified: nil)
        let doc = WebDavItem(name: "d.doc", path: "/d.doc", isDirectory: false, size: 0, modified: nil)
        XCTAssertTrue(pdf.isPreviewablePDF)
        XCTAssertFalse(doc.isPreviewablePDF)
    }

    func testWebDavItemDisplaySizeDirectory() {
        let dir = WebDavItem(name: "d", path: "/d", isDirectory: true, size: 0, modified: nil)
        XCTAssertEqual(dir.displaySize, "—")
    }

    func testWebDavItemDisplaySizeFile() {
        let file = WebDavItem(name: "f.txt", path: "/f.txt", isDirectory: false, size: 1024, modified: nil)
        XCTAssertEqual(file.displaySize, "1.0 KB")
    }

    func testWebDavItemDisplayKindImage() {
        let item = WebDavItem(name: "p.jpeg", path: "/p.jpeg", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.displayKind, "Image")
    }

    func testWebDavItemDisplayKindVideo() {
        let item = WebDavItem(name: "v.mp4", path: "/v.mp4", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.displayKind, "Video")
    }

    func testWebDavItemDisplayKindFolder() {
        let item = WebDavItem(name: "dir", path: "/dir", isDirectory: true, size: 0, modified: nil)
        XCTAssertEqual(item.displayKind, "Folder")
    }

    func testWebDavItemDisplayKindUnknown() {
        let item = WebDavItem(name: "data.xyz", path: "/data.xyz", isDirectory: false, size: 0, modified: nil)
        XCTAssertTrue(item.displayKind.contains("XYZ") || item.displayKind.contains("File"))
    }

    func testWebDavItemIdIsPath() {
        let item = WebDavItem(name: "f.txt", path: "/sub/f.txt", isDirectory: false, size: 0, modified: nil)
        XCTAssertEqual(item.id, "/sub/f.txt")
    }
}
