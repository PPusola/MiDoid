import XCTest
@testable import SyncCompanion

@MainActor
final class SessionStateTests: XCTestCase {

    // MARK: - formatInterval

    func testFormatIntervalSeconds() {
        XCTAssertEqual(SessionState.formatInterval(45), "45s")
    }

    func testFormatIntervalOneSecond() {
        XCTAssertEqual(SessionState.formatInterval(1), "1s")
    }

    func testFormatIntervalZeroSeconds() {
        XCTAssertEqual(SessionState.formatInterval(0), "0s")
    }

    func testFormatIntervalExactMinute() {
        XCTAssertEqual(SessionState.formatInterval(60), "1m 00s")
    }

    func testFormatIntervalMinutesAndSeconds() {
        XCTAssertEqual(SessionState.formatInterval(125), "2m 05s")
    }

    func testFormatIntervalExactHour() {
        XCTAssertEqual(SessionState.formatInterval(3600), "1h 00m")
    }

    func testFormatIntervalHoursAndMinutes() {
        XCTAssertEqual(SessionState.formatInterval(3661), "1h 01m")
    }

    func testFormatIntervalLargeValue() {
        XCTAssertEqual(SessionState.formatInterval(7260), "2h 01m")
    }

    // MARK: - Status transitions

    func testInitialStatusIsIdle() {
        let state = SessionState()
        XCTAssertEqual(state.status, .idle)
    }

    func testSetConnecting() {
        let state = SessionState()
        state.setConnecting()
        XCTAssertEqual(state.status, .connecting)
    }

    func testSetError() {
        let state = SessionState()
        state.setError("connection failed")
        XCTAssertEqual(state.status, .error("connection failed"))
    }

    func testSetIdle() {
        let state = SessionState()
        state.setConnecting()
        state.setIdle()
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.timeRemaining, "")
        XCTAssertEqual(state.deviceName, "")
        XCTAssertNil(state.incomingTransfer)
    }

    func testSetConnected() {
        let state = SessionState()
        state.setConnected(ip: "192.168.1.5", port: 8080, token: "tok", expiry: nil)
        if case .connected(let ip, let port, let token, let expiry) = state.status {
            XCTAssertEqual(ip, "192.168.1.5")
            XCTAssertEqual(port, 8080)
            XCTAssertEqual(token, "tok")
            XCTAssertNil(expiry)
        } else {
            XCTFail("Expected .connected status")
        }
    }

    // MARK: - menuBarTint

    func testMenuBarTintNilWhenIdle() {
        let state = SessionState()
        XCTAssertNil(state.menuBarTint)
    }

    func testMenuBarTintNilWhenConnecting() {
        let state = SessionState()
        state.setConnecting()
        XCTAssertNil(state.menuBarTint)
    }

    func testMenuBarTintGreenWhenConnected() {
        let state = SessionState()
        state.setConnected(ip: "10.0.0.1", port: 8080, token: "t", expiry: nil)
        XCTAssertEqual(state.menuBarTint, NSColor.systemGreen)
    }

    func testMenuBarTintRedWhenError() {
        let state = SessionState()
        state.setError("err")
        XCTAssertEqual(state.menuBarTint, NSColor.systemRed)
    }

    // MARK: - updateIncomingTransfer

    func testUpdateIncomingTransfer() {
        let state = SessionState()
        state.updateIncomingTransfer(filename: "video.mp4", deviceName: "Pixel 9",
                                     receivedBytes: 500, totalBytes: 1000)
        XCTAssertNotNil(state.incomingTransfer)
        XCTAssertEqual(state.incomingTransfer?.filename, "video.mp4")
        XCTAssertEqual(state.incomingTransfer?.progress, 0.5, accuracy: 0.001)
    }

    // MARK: - IncomingTransfer

    func testIncomingTransferProgressCalculation() {
        let t = IncomingTransfer(filename: "f", deviceName: "d", receivedBytes: 300, totalBytes: 1000)
        XCTAssertEqual(t.progress, 0.3, accuracy: 0.001)
    }

    func testIncomingTransferProgressZeroWhenTotalZero() {
        let t = IncomingTransfer(filename: "f", deviceName: "d", receivedBytes: 100, totalBytes: 0)
        XCTAssertEqual(t.progress, 0.0)
    }

    func testIncomingTransferDetailWithTotal() {
        let t = IncomingTransfer(filename: "f", deviceName: "d", receivedBytes: 1024, totalBytes: 2048)
        XCTAssertTrue(t.detail.contains("of"))
    }

    func testIncomingTransferDetailWithoutTotal() {
        let t = IncomingTransfer(filename: "f", deviceName: "d", receivedBytes: 1024, totalBytes: 0)
        XCTAssertFalse(t.detail.contains("of"))
    }
}
