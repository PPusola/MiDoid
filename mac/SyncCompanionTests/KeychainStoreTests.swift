import XCTest
@testable import SyncCompanion

final class KeychainStoreTests: XCTestCase {

    private let key = "com.synccompanion.tests.keychain.\(UUID().uuidString)"

    override func tearDown() {
        super.tearDown()
        KeychainStore.delete(forKey: key)
    }

    // MARK: - save / load round-trip

    func testSaveAndLoad() throws {
        let data = Data("secret-value".utf8)
        try KeychainStore.save(data, forKey: key)
        XCTAssertEqual(KeychainStore.load(forKey: key), data)
    }

    func testSaveEmptyData() throws {
        try KeychainStore.save(Data(), forKey: key)
        XCTAssertEqual(KeychainStore.load(forKey: key), Data())
    }

    func testSaveBinaryData() throws {
        let data = Data([0x00, 0xFF, 0x10, 0xAB, 0xCD])
        try KeychainStore.save(data, forKey: key)
        XCTAssertEqual(KeychainStore.load(forKey: key), data)
    }

    // MARK: - load missing

    func testLoadMissingReturnsNil() {
        KeychainStore.delete(forKey: key)
        XCTAssertNil(KeychainStore.load(forKey: key))
    }

    // MARK: - delete

    func testDeleteRemovesItem() throws {
        try KeychainStore.save(Data("x".utf8), forKey: key)
        KeychainStore.delete(forKey: key)
        XCTAssertNil(KeychainStore.load(forKey: key))
    }

    func testDeleteNonExistentIsNoop() {
        // Should not throw or crash
        KeychainStore.delete(forKey: key + "-missing")
    }

    // MARK: - overwrite

    func testOverwriteReplacesValue() throws {
        try KeychainStore.save(Data("first".utf8), forKey: key)
        try KeychainStore.save(Data("second".utf8), forKey: key)
        XCTAssertEqual(KeychainStore.load(forKey: key), Data("second".utf8))
    }

    // MARK: - key isolation

    func testDifferentKeysAreIndependent() throws {
        let keyA = key + "-A"
        let keyB = key + "-B"
        defer { KeychainStore.delete(forKey: keyA); KeychainStore.delete(forKey: keyB) }

        try KeychainStore.save(Data("A".utf8), forKey: keyA)
        try KeychainStore.save(Data("B".utf8), forKey: keyB)

        XCTAssertEqual(KeychainStore.load(forKey: keyA), Data("A".utf8))
        XCTAssertEqual(KeychainStore.load(forKey: keyB), Data("B".utf8))
    }

    func testDeleteOneKeyLeavesOtherIntact() throws {
        let keyA = key + "-A"
        let keyB = key + "-B"
        defer { KeychainStore.delete(forKey: keyA); KeychainStore.delete(forKey: keyB) }

        try KeychainStore.save(Data("A".utf8), forKey: keyA)
        try KeychainStore.save(Data("B".utf8), forKey: keyB)
        KeychainStore.delete(forKey: keyA)

        XCTAssertNil(KeychainStore.load(forKey: keyA))
        XCTAssertEqual(KeychainStore.load(forKey: keyB), Data("B".utf8))
    }

    // MARK: - FileBrowserViewModel.formatBytes (static, accessible from test target)

    func testFormatBytesZero() {
        XCTAssertEqual(FileBrowserViewModel.formatBytes(0), "0 B")
    }

    func testFormatBytesUnderKB() {
        XCTAssertEqual(FileBrowserViewModel.formatBytes(512), "512 B")
    }

    func testFormatBytesKilobytes() {
        XCTAssertEqual(FileBrowserViewModel.formatBytes(1536), "1.5 KB")
    }

    func testFormatBytesMegabytes() {
        XCTAssertEqual(FileBrowserViewModel.formatBytes(1_572_864), "1.5 MB")
    }

    func testFormatBytesGigabytes() {
        XCTAssertEqual(FileBrowserViewModel.formatBytes(1_610_612_736), "1.50 GB")
    }

    func testFormatBytesExactKB() {
        XCTAssertEqual(FileBrowserViewModel.formatBytes(1024), "1.0 KB")
    }

    func testFormatBytesExactMB() {
        XCTAssertEqual(FileBrowserViewModel.formatBytes(1_048_576), "1.0 MB")
    }
}
