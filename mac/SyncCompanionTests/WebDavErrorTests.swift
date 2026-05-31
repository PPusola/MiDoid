import XCTest
@testable import SyncCompanion

final class WebDavErrorTests: XCTestCase {

    // MARK: - HTTP status codes

    func testFriendly403() {
        let msg = WebDavError.friendly(WebDavError.httpStatus(403))
        XCTAssertTrue(msg.lowercased().contains("denied") || msg.lowercased().contains("blocked"))
    }

    func testFriendly404() {
        let msg = WebDavError.friendly(WebDavError.httpStatus(404))
        XCTAssertTrue(msg.lowercased().contains("not found"))
    }

    func testFriendly405() {
        let msg = WebDavError.friendly(WebDavError.httpStatus(405))
        XCTAssertTrue(msg.lowercased().contains("not allowed") || msg.lowercased().contains("operation"))
    }

    func testFriendly409() {
        let msg = WebDavError.friendly(WebDavError.httpStatus(409))
        XCTAssertTrue(msg.lowercased().contains("conflict") || msg.lowercased().contains("folder"))
    }

    func testFriendly507() {
        let msg = WebDavError.friendly(WebDavError.httpStatus(507))
        XCTAssertTrue(msg.lowercased().contains("storage") || msg.lowercased().contains("full"))
    }

    func testFriendlyUnknownStatusIncludesCode() {
        let msg = WebDavError.friendly(WebDavError.httpStatus(500))
        XCTAssertTrue(msg.contains("500"))
    }

    func testFriendlyUnknownStatusIncludesCode503() {
        let msg = WebDavError.friendly(WebDavError.httpStatus(503))
        XCTAssertTrue(msg.contains("503"))
    }

    // MARK: - Named errors

    func testFriendlyLocalNetworkProhibited() {
        let msg = WebDavError.friendly(WebDavError.localNetworkProhibited)
        XCTAssertTrue(msg.lowercased().contains("local network") || msg.lowercased().contains("system settings"))
    }

    func testFriendlyAndroidUnreachable() {
        let msg = WebDavError.friendly(WebDavError.androidUnreachable)
        XCTAssertTrue(msg.lowercased().contains("android") || msg.lowercased().contains("unreachable"))
    }

    // MARK: - URLError cases

    func testFriendlyTimedOutMentionsSleep() {
        let msg = WebDavError.friendly(URLError(.timedOut))
        XCTAssertTrue(
            msg.lowercased().contains("screen") ||
            msg.lowercased().contains("sleep") ||
            msg.lowercased().contains("timed")
        )
    }

    func testFriendlyNetworkConnectionLostMentionsWifi() {
        let msg = WebDavError.friendly(URLError(.networkConnectionLost))
        XCTAssertTrue(
            msg.lowercased().contains("wi-fi") ||
            msg.lowercased().contains("connection") ||
            msg.lowercased().contains("dropped")
        )
    }

    func testFriendlyNotConnectedToInternet() {
        let msg = WebDavError.friendly(URLError(.notConnectedToInternet))
        XCTAssertFalse(msg.isEmpty)
    }

    func testFriendlyCannotConnectToHost() {
        let msg = WebDavError.friendly(URLError(.cannotConnectToHost))
        XCTAssertTrue(msg.lowercased().contains("android") || msg.lowercased().contains("device") || msg.lowercased().contains("reach"))
    }

    func testFriendlyCannotFindHost() {
        let msg = WebDavError.friendly(URLError(.cannotFindHost))
        XCTAssertTrue(
            msg.lowercased().contains("wi-fi") ||
            msg.lowercased().contains("find") ||
            msg.lowercased().contains("reconnect")
        )
    }

    func testFriendlyNeverEmpty() {
        let errors: [Error] = [
            WebDavError.httpStatus(200),
            WebDavError.httpStatus(403),
            WebDavError.httpStatus(404),
            WebDavError.httpStatus(507),
            WebDavError.localNetworkProhibited,
            WebDavError.androidUnreachable,
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            URLError(.cannotConnectToHost),
            URLError(.cannotFindHost),
        ]
        for error in errors {
            XCTAssertFalse(WebDavError.friendly(error).isEmpty, "Message empty for \(error)")
        }
    }

    // MARK: - errorDescription

    func testErrorDescriptionHttpStatus() {
        XCTAssertNotNil(WebDavError.httpStatus(404).errorDescription)
    }

    func testErrorDescriptionLocalNetworkProhibited() {
        XCTAssertNotNil(WebDavError.localNetworkProhibited.errorDescription)
    }

    func testErrorDescriptionAndroidUnreachable() {
        XCTAssertNotNil(WebDavError.androidUnreachable.errorDescription)
    }
}
