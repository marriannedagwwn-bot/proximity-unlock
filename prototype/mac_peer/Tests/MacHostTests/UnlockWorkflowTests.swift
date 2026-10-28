import CoreImage
import Foundation
import XCTest
@testable import MacHost
import PeerCore

final class UnlockWorkflowTests: XCTestCase {
    func testEnrollmentQRCodeDecodesToSameCode() throws {
        let text = #"{"keyID":4294967295,"secret":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","version":1}"#
        let image = try XCTUnwrap(EnrollmentQRCode.cgImage(for: text))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let decoded = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(decoded, [text])
    }

    func testSuccessfulUnicodePasswordRequiresRealUnlock() async {
        let driver = FakeDriver()
        driver.reportMaskAsCharacters = true
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "測試👩🏽‍💻e\u{301}")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(driver.keys, [0x33, 0x24])
        XCTAssertEqual(driver.values, ["", "測試👩🏽‍💻e\u{301}"])
        XCTAssertFalse(driver.locked!)
    }

    func testMissingEitherPermissionNeverWritesOrPosts() async {
        for permission in [UnlockPermissions(accessibility: false, postEvents: true),
                           UnlockPermissions(accessibility: true, postEvents: false)] {
            let driver = FakeDriver()
            driver.permission = permission
            let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
            XCTAssertFalse(result.ok)
            XCTAssertTrue(driver.values.isEmpty)
            XCTAssertTrue(driver.keys.isEmpty)
        }
    }

    func testOrdinaryOrNonWritableFocusIsRejectedBeforeInput() async {
        let driver = FakeDriver()
        driver.focus = nil // driver 不将普通文本框、别的进程、不可写密码框作为安全焦点返回。
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(driver.values.isEmpty)
        XCTAssertTrue(driver.keys.isEmpty)
    }

    func testWaitsForDelayedSafePasswordFieldWithoutInput() async {
        let driver = FakeDriver()
        driver.focusAvailableAt = 0.5
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertTrue(result.ok)
        XCTAssertGreaterThanOrEqual(driver.keyTimes.first ?? 0, 0.5)
        XCTAssertEqual(driver.keys, [0x33, 0x24])
        XCTAssertEqual(driver.values, ["", "fake-password"])
    }

    func testSafeFieldReadinessTimesOutWithoutAnyInput() async {
        let driver = FakeDriver()
        driver.focusAvailableAt = 3
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertGreaterThanOrEqual(driver.time, 2)
        XCTAssertTrue(driver.values.isEmpty)
        XCTAssertTrue(driver.keys.isEmpty)
    }

    func testCancelledWhileWaitingForFieldNeverInputs() async {
        let driver = FakeDriver()
        driver.focusAvailableAt = 1
        driver.cancelAtPause = 1
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.note, ScreenUnlockFailure.cancelled.note)
        XCTAssertTrue(driver.values.isEmpty)
        XCTAssertTrue(driver.keys.isEmpty)
    }

    func testSessionSwitchWhileWaitingForFieldNeverInputs() async {
        let driver = FakeDriver()
        driver.focusAvailableAt = 1
        driver.sessionChangeOnPause = true
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(driver.values.isEmpty)
        XCTAssertTrue(driver.keys.isEmpty)
    }

    func testUnknownLockStateIsNeverSuccess() async {
        let driver = FakeDriver()
        driver.locked = nil
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(driver.values.isEmpty)
    }

    func testOtherConsoleUserIsRejectedBeforeInput() async {
        let driver = FakeDriver()
        driver.session = nil
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(driver.values.isEmpty)
        XCTAssertTrue(driver.keys.isEmpty)
    }

    func testFocusChangeAfterDeleteDoesNotSendSecretToNewField() async {
        let driver = FakeDriver()
        driver.focusChangeOnPause = true
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(driver.keys, [0x33])
        XCTAssertTrue(driver.values.isEmpty)
    }

    func testSessionSwitchAfterDeleteStopsBeforeWriting() async {
        let driver = FakeDriver()
        driver.sessionChangeOnPause = true
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(driver.keys, [0x33])
        XCTAssertTrue(driver.values.isEmpty)
    }

    func testValueReadbackTimeoutNeverSubmitsPassword() async {
        let driver = FakeDriver()
        driver.secretLengthIsUnavailable = true
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(driver.keys, [0x33])
        XCTAssertEqual(driver.values, ["", "fake-password", ""])
    }

    func testAXWriteFailureAfterApplyingSecretStillClearsOwnSafeField() async {
        let driver = FakeDriver()
        driver.failAfterApplyingSecret = true
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(driver.keys, [0x33])
        XCTAssertEqual(driver.values, ["", "fake-password", ""])
        XCTAssertEqual(driver.content, "")
    }

    func testReturnWithoutRealUnlockTimesOutAndDoesNotRetry() async {
        let driver = FakeDriver()
        driver.unlockOnReturn = false
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(driver.keys, [0x33, 0x24])
        XCTAssertEqual(driver.values, ["", "fake-password", ""])
        XCTAssertGreaterThanOrEqual(driver.time, 7)
    }

    func testUnknownStateAfterReturnDoesNotClaimSuccess() async {
        let driver = FakeDriver()
        driver.unknownAfterReturn = true
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(driver.keys, [0x33, 0x24])
    }

    func testCancelledOperationStopsAndClearsOnlyItsOwnField() async {
        let driver = FakeDriver()
        driver.unlockOnReturn = false
        driver.cancelAtPause = 2 // Return 后的首次确认等待被取消。
        let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: "fake-password")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.note, ScreenUnlockFailure.cancelled.note)
        XCTAssertEqual(driver.keys, [0x33, 0x24])
        XCTAssertEqual(driver.values.last, "")
    }

    func testConcurrentRequestIsRejectedWhileFirstAwaits() async {
        let driver = FakeDriver()
        let gate = PauseGate()
        driver.gate = gate
        let workflow = ScreenUnlockWorkflow(driver: driver)
        let first = Task { await workflow.unlock(password: "first-fake-password") }
        await gate.waitUntilBlocked()
        let second = await workflow.unlock(password: "second-fake-password")
        XCTAssertFalse(second.ok)
        XCTAssertEqual(second.note, "已有一次解锁正在进行")
        await gate.release()
        let firstResult = await first.value
        XCTAssertTrue(firstResult.ok)
        XCTAssertFalse(driver.values.contains("second-fake-password"))
    }

    func testInvalidPasswordNeverTouchesDriver() async {
        for value in ["", "contains\0nul"] {
            let driver = FakeDriver()
            let result = await ScreenUnlockWorkflow(driver: driver).unlock(password: value)
            XCTAssertFalse(result.ok)
            XCTAssertTrue(driver.values.isEmpty)
            XCTAssertTrue(driver.keys.isEmpty)
        }
    }

    func testCredentialValidationRejectsDifferentUserAndMalformedKeyWithoutKeychainAccess() throws {
        let valid = StoredUnlockCredential(username: NSUserName(), password: "fake-password",
                                           key: UnlockKey(id: 1, secret: Data(repeating: 7, count: 32)))
        XCTAssertNoThrow(try MacUnlockStore.validate(valid))
        XCTAssertThrowsError(try MacUnlockStore.validate(StoredUnlockCredential(
            username: NSUserName() + "-different", password: "fake-password", key: valid.key)))
        XCTAssertThrowsError(try MacUnlockStore.validate(StoredUnlockCredential(
            username: NSUserName(), password: "fake-password", key: UnlockKey(id: 1, secret: Data(repeating: 7, count: 31)))))
        XCTAssertThrowsError(try MacUnlockStore.validate(StoredUnlockCredential(
            username: NSUserName(), password: "fake-password", key: UnlockKey(id: 1, secret: Data(repeating: 0, count: 32)))))
    }
}

private final class FakeDriver: ScreenUnlockDriver {
    var permission = UnlockPermissions(accessibility: true, postEvents: true)
    var session: UnlockSession? = UnlockSession(username: "fake-user", uid: 501, auditID: 123)
    var locked: Bool? = true
    var focus: Int? = 1
    var values: [String] = []
    var keys: [UInt16] = []
    var keyTimes: [TimeInterval] = []
    var content = ""
    var time: TimeInterval = 0
    var pauseCount = 0
    var unlockOnReturn = true
    var unknownAfterReturn = false
    var focusChangeOnPause = false
    var sessionChangeOnPause = false
    var secretLengthIsUnavailable = false
    var failAfterApplyingSecret = false
    var reportMaskAsCharacters = false
    var focusAvailableAt: TimeInterval = 0
    var cancelAtPause: Int?
    var gate: PauseGate?

    func permissions() -> UnlockPermissions { permission }
    func currentSession() -> UnlockSession? { session }
    func lockedState() -> Bool? { locked }
    func focusedPasswordField() -> Int? { time >= focusAvailableAt ? focus : nil }
    func writeValue(_ value: String, to field: Int) throws {
        guard field == focus else { throw ScreenUnlockFailure.focus }
        values.append(value)
        content = value
        if !value.isEmpty && failAfterApplyingSecret { throw ScreenUnlockFailure.fieldWrite }
    }
    func fieldLength(_ field: Int) -> Int? {
        if !content.isEmpty && secretLengthIsUnavailable { return nil }
        return reportMaskAsCharacters ? content.count : content.utf16.count
    }
    func pressKey(_ code: UInt16) async throws {
        keys.append(code)
        keyTimes.append(time)
        if code == 0x24 {
            locked = unknownAfterReturn ? nil : !unlockOnReturn
        }
    }
    func monotonicTime() -> TimeInterval { time }
    func pause(_ interval: TimeInterval) async throws {
        pauseCount += 1
        if let gate, pauseCount == 1 { await gate.block() }
        if pauseCount == cancelAtPause { throw CancellationError() }
        time += interval
        if focusChangeOnPause { focus = 2 }
        if sessionChangeOnPause { session = UnlockSession(username: "other", uid: 502, auditID: 456) }
    }
}

private actor PauseGate {
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func block() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            blocked = true
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
