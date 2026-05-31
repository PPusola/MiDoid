import XCTest
@testable import SyncCompanion

final class IncomingFileServerTests: XCTestCase {

    private let defaultsKey = IncomingFileServer.landingFolderDefaultsKey

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: - folderName(for:)

    func testFolderNameJpeg() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "photo.jpg"), "Photos")
    }

    func testFolderNamePng() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "screenshot.png"), "Photos")
    }

    func testFolderNameHeic() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "live.heic"), "Photos")
    }

    func testFolderNameWebp() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "img.webp"), "Photos")
    }

    func testFolderNameMp4() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "clip.mp4"), "Videos")
    }

    func testFolderNameMov() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "screen.mov"), "Videos")
    }

    func testFolderNameMkv() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "movie.mkv"), "Videos")
    }

    func testFolderNameMp3() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "song.mp3"), "Audio")
    }

    func testFolderNameFlac() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "album.flac"), "Audio")
    }

    func testFolderNameAac() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "voice.aac"), "Audio")
    }

    func testFolderNamePdf() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "report.pdf"), "Documents")
    }

    func testFolderNameTxt() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "notes.txt"), "Documents")
    }

    func testFolderNameDocx() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "letter.docx"), "Documents")
    }

    func testFolderNameZip() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "backup.zip"), "Archives")
    }

    func testFolderNameTar() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "source.tar"), "Archives")
    }

    func testFolderNameGz() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "data.gz"), "Archives")
    }

    func testFolderNameUnknownExtension() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "app.apk"), "Other")
    }

    func testFolderNameNoExtension() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "Makefile"), "Other")
    }

    func testFolderNameCaseInsensitiveJpg() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "PHOTO.JPG"), "Photos")
    }

    func testFolderNameCaseInsensitiveMp4() {
        XCTAssertEqual(IncomingFileServer.folderName(for: "CLIP.MP4"), "Videos")
    }

    // MARK: - uniqueURL(in:filename:)

    func testUniqueURLNoConflict() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = IncomingFileServer.uniqueURL(in: dir, filename: "photo.jpg")
        XCTAssertEqual(url.lastPathComponent, "photo.jpg")
    }

    func testUniqueURLOneConflict() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("photo.jpg"))

        let url = IncomingFileServer.uniqueURL(in: dir, filename: "photo.jpg")
        XCTAssertEqual(url.lastPathComponent, "photo 1.jpg")
    }

    func testUniqueURLTwoConflicts() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try Data().write(to: dir.appendingPathComponent("photo.jpg"))
        try Data().write(to: dir.appendingPathComponent("photo 1.jpg"))

        let url = IncomingFileServer.uniqueURL(in: dir, filename: "photo.jpg")
        XCTAssertEqual(url.lastPathComponent, "photo 2.jpg")
    }

    func testUniqueURLNoExtension() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try Data().write(to: dir.appendingPathComponent("readme"))

        let url = IncomingFileServer.uniqueURL(in: dir, filename: "readme")
        XCTAssertEqual(url.lastPathComponent, "readme 1")
    }

    func testUniqueURLPreservesDirectory() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = IncomingFileServer.uniqueURL(in: dir, filename: "file.txt")
        XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
    }

    // MARK: - landingFolder()

    func testLandingFolderDefaultContainsDownloadsMiDoid() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let folder = IncomingFileServer.landingFolder()
        XCTAssertTrue(folder.path.contains("Downloads/MiDoid"))
    }

    func testLandingFolderUsesUserDefaults() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        IncomingFileServer.setLandingFolder(dir)
        XCTAssertEqual(IncomingFileServer.landingFolder().path, dir.path)
    }

    func testLandingFolderFallsBackIfPathMissing() {
        UserDefaults.standard.set("/nonexistent/\(UUID().uuidString)", forKey: defaultsKey)
        let folder = IncomingFileServer.landingFolder()
        XCTAssertTrue(folder.path.contains("Downloads/MiDoid"))
    }

    func testSetLandingFolderPersists() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        IncomingFileServer.setLandingFolder(dir)
        let saved = UserDefaults.standard.string(forKey: defaultsKey)
        XCTAssertEqual(saved, dir.path)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
