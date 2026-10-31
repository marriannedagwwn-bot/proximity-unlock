import Foundation
import XCTest
@testable import PeerCore

final class UnlockProtocolTests: XCTestCase {
    private let key = UnlockKey(id: 0x01020304, secret: Data(0..<32))
    private let central = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let nonce = Data(0..<16)

    private func gate() -> UnlockGate {
        let gate = UnlockGate(key: key)
        gate.sync(promptID: 0x1234, now: 100)
        return gate
    }

    private func command(_ gate: UnlockGate, now: Double = 101, central: UUID? = nil) throws -> Data {
        let bytes = try gate.challenge(for: central ?? self.central, now: now, nonce: nonce).get()
        return UnlockProtocol.command(key: key, challenge: try XCTUnwrap(UnlockProtocol.parseChallenge(bytes)))
    }

    private func failure(_ result: Result<Void, UnlockStatus>, _ expected: UnlockStatus,
                         file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("请求不应通过", file: file, line: line)
        case .failure(let status): XCTAssertEqual(status, expected, file: file, line: line)
        }
    }

    func testEnrollAckMatchesWindowsAndAppVector() {
        // 和 Windows 的 tests/test_win_unlock_protocol.py、App 的 ios/test-unlock-codec.sh 同一个向量
        let key = UnlockKey(id: 0x78563412, secret: Data(0..<32))
        let ack = EnrollProtocol.ack(key: key, reportNonce: nonce)
        XCTAssertEqual(ack.map { String(format: "%02x", $0) }.joined(), "12345678e8a232851651af8c3a8c9efbbeb9ab78")
        XCTAssertEqual(EnrollProtocol.ackKeyID(ack), 0x78563412)
        XCTAssertTrue(EnrollProtocol.verifyAck(ack, key: key, reportNonce: nonce))
        var tampered = ack
        tampered[tampered.count - 1] ^= 1
        XCTAssertFalse(EnrollProtocol.verifyAck(tampered, key: key, reportNonce: nonce))
        XCTAssertFalse(EnrollProtocol.verifyAck(ack, key: key, reportNonce: Data(repeating: 0, count: 16)), "换了电脑端进程旧确认不认")
        XCTAssertFalse(EnrollProtocol.verifyAck(ack, key: UnlockKey(id: 0x78563412, secret: Data(repeating: 0, count: 32)),
                                               reportNonce: nonce))
        XCTAssertFalse(EnrollProtocol.verifyAck(ack.dropLast(), key: key, reportNonce: nonce))
        XCTAssertNil(EnrollProtocol.ackKeyID(ack + Data([0])))
    }

    func testKnownHMACVectorAndLittleEndianWireFormat() throws {
        let challenge = UnlockProtocol.Challenge(promptID: 0x1234, nonce: nonce)
        XCTAssertEqual(challenge.data.map { String(format: "%02x", $0) }.joined(),
                       "3412000102030405060708090a0b0c0d0e0f")
        // 独立用 Python hmac/hashlib 对固定消息计算的截断向量。
        XCTAssertEqual(UnlockProtocol.tag(key: key, challenge: challenge).map { String(format: "%02x", $0) }.joined(),
                       "4b78d367ade22f9aee438984eccfd654")
        XCTAssertEqual(UnlockProtocol.command(key: key, challenge: challenge).map { String(format: "%02x", $0) }.joined(),
                       "0403020134124b78d367ade22f9aee438984eccfd654")
        XCTAssertEqual(UnlockProtocol.parseChallenge(challenge.data), challenge)
        XCTAssertNil(UnlockProtocol.parseChallenge(Data(challenge.data.dropLast())))
        XCTAssertNil(UnlockProtocol.parseChallenge(challenge.data + Data([0])))
    }

    func testNoPromptAndIneligibleRequestAreRejected() throws {
        let empty = UnlockGate(key: key)
        XCTAssertThrowsError(try empty.challenge(for: central, now: 100).get())
        failure(empty.authorize(Data(), from: central, now: 100, eligible: true), .unavailable)
        let gate = gate()
        let request = try command(gate)
        failure(gate.authorize(request, from: central, now: 101, eligible: false), .unavailable)
        failure(gate.authorize(request, from: central, now: 101, eligible: true), .invalidChallenge)
    }

    func testAcceptedRequestCannotReplayOrRunConcurrently() throws {
        let gate = gate()
        let request = try command(gate)
        try gate.authorize(request, from: central, now: 101, eligible: true).get()
        XCTAssertTrue(gate.inFlight)
        failure(gate.authorize(request, from: central, now: 102, eligible: true), .unavailable)
        XCTAssertThrowsError(try gate.challenge(for: central, now: 102).get())
        gate.finish()
        failure(gate.authorize(request, from: central, now: 102, eligible: true), .invalidChallenge)
    }

    func testChallengeExpiresAndCannotBeRenewedForSamePrompt() throws {
        let gate = gate()
        let request = try command(gate)
        failure(gate.authorize(request, from: central, now: 220.01, eligible: true), .invalidChallenge)
        XCTAssertThrowsError(try gate.challenge(for: central, now: 221).get())
        gate.sync(promptID: 0x1235, now: 221)
        XCTAssertNoThrow(try gate.challenge(for: central, now: 221, nonce: nonce).get())
    }

    func testClockRollbackAndInvalidNonceAreRejected() throws {
        let gate = gate()
        XCTAssertThrowsError(try gate.challenge(for: central, now: 99, nonce: nonce).get())
        XCTAssertThrowsError(try gate.challenge(for: central, now: 101, nonce: Data([0])).get())
        XCTAssertThrowsError(try gate.challenge(for: central, now: .nan, nonce: nonce).get())
    }

    func testPromptChangeOrCancellationInvalidatesNonce() throws {
        let gate = gate()
        let old = try command(gate)
        gate.sync(promptID: 0x1235, now: 102)
        failure(gate.authorize(old, from: central, now: 102, eligible: true), .invalidChallenge)
        _ = try command(gate, now: 103)
        gate.sync(promptID: nil, now: 104)
        failure(gate.authorize(old, from: central, now: 104, eligible: true), .unavailable)
    }

    func testChallengeIsBoundToCentralAndConsumedOnFailure() throws {
        let gate = gate()
        let request = try command(gate)
        XCTAssertThrowsError(try gate.challenge(for: other, now: 101).get())
        failure(gate.authorize(request, from: other, now: 101, eligible: true), .unavailable)
        failure(gate.authorize(request, from: central, now: 101, eligible: true), .invalidChallenge)
    }

    func testWrongKeyAndPromptIdentifiersAreRejected() throws {
        let gate = gate()
        var request = try command(gate)
        request[0] ^= 1
        failure(gate.authorize(request, from: central, now: 101, eligible: true), .unavailable)
        request = try command(gate, now: 102)
        request[4] ^= 1
        failure(gate.authorize(request, from: central, now: 102, eligible: true), .unavailable)
    }

    func testThreeFailedSignaturesClosePromptUntilItChanges() throws {
        let gate = gate()
        for n in 0..<3 {
            var request = try command(gate, now: 101 + Double(n))
            request[21] ^= 1
            failure(gate.authorize(request, from: central, now: 101 + Double(n), eligible: true), .invalidSignature)
        }
        XCTAssertEqual(gate.failures, 3)
        XCTAssertThrowsError(try gate.challenge(for: central, now: 105).get())
        gate.sync(promptID: 0x1234, now: 105)
        XCTAssertEqual(gate.failures, 3)
        gate.sync(promptID: nil, now: 105)
        gate.sync(promptID: 0x1234, now: 105)
        XCTAssertEqual(gate.failures, 3)
        gate.sync(promptID: 0x1235, now: 106)
        XCTAssertEqual(gate.failures, 0)
        XCTAssertNoThrow(try gate.challenge(for: central, now: 106, nonce: nonce).get())
    }

    func testMalformedCommandConsumesChallengeAndInvalidKeyNeverEnables() throws {
        let gate = gate()
        let request = try command(gate)
        failure(gate.authorize(Data(request.dropLast()), from: central, now: 101, eligible: true), .invalidSignature)
        failure(gate.authorize(request, from: central, now: 101, eligible: true), .invalidChallenge)
        let bad = UnlockGate(key: UnlockKey(id: 1, secret: Data([0])))
        bad.sync(promptID: 1, now: 100)
        XCTAssertThrowsError(try bad.challenge(for: central, now: 101).get())
    }

    func testPromptChangeCannotBypassInFlightAndExecutionFailuresCount() throws {
        let gate = gate()
        let request = try command(gate)
        try gate.authorize(request, from: central, now: 101, eligible: true).get()
        gate.finish(succeeded: false)
        XCTAssertEqual(gate.failures, 1)
        let next = try command(gate, now: 102)
        try gate.authorize(next, from: central, now: 102, eligible: true).get()
        gate.sync(promptID: 0x1235, now: 103)
        XCTAssertThrowsError(try gate.challenge(for: central, now: 103).get())
        gate.finish(succeeded: false)
        XCTAssertEqual(gate.failures, 0)
        XCTAssertNoThrow(try gate.challenge(for: central, now: 104, nonce: nonce).get())
    }

    // MARK: - 手动解锁、手机锁屏（docs/protocol.md「手动锁屏、解锁」）

    func testManualChallengeUsesPromptZeroAndOwnLifetime() throws {
        let gate = UnlockGate(key: key)
        gate.sync(promptID: UnlockProtocol.manualPromptID, now: 1000)
        // 手动解锁不看提示的 120 秒：锁了很久以后点也行，随机数从发出起 30 秒有效
        let bytes = try gate.challenge(for: central, now: 5000, nonce: nonce).get()
        let challenge = try XCTUnwrap(UnlockProtocol.parseChallenge(bytes))
        XCTAssertEqual(challenge.promptID, 0)
        // 和 App 的 ios/test-unlock-codec.sh 同一个向量（Python hmac 独立算的）
        let vectorKey = UnlockKey(id: 0x78563412, secret: Data(0..<32))
        XCTAssertEqual(UnlockProtocol.command(key: vectorKey, challenge: challenge).map { String(format: "%02x", $0) }.joined(),
                       "1234567800004a778d2cb1f5141a5d8edd20c871dac0")
        let request = UnlockProtocol.command(key: key, challenge: challenge)
        failure(gate.authorize(request, from: central, now: 5030.01, eligible: true), .invalidChallenge)
        // 过期的换新随机数，不用等状态变
        let renewed = try gate.challenge(for: central, now: 5031, nonce: Data(repeating: 7, count: 16)).get()
        XCTAssertNotEqual(renewed, bytes)
        let next = UnlockProtocol.command(key: key, challenge: try XCTUnwrap(UnlockProtocol.parseChallenge(renewed)))
        try gate.authorize(next, from: central, now: 5032, eligible: true).get()
        gate.finish()
    }

    func testManualAndPromptSignaturesAreNotInterchangeable() throws {
        let gate = UnlockGate(key: key)
        gate.sync(promptID: UnlockProtocol.manualPromptID, now: 100)
        let manual = try command(gate)
        // 电脑开始请提示：手动的随机数作废，签名也带着编号 0，解不了提示
        gate.sync(promptID: 0x1234, now: 101)
        failure(gate.authorize(manual, from: central, now: 101, eligible: true), .invalidChallenge)
        let prompt = try command(gate, now: 102)
        gate.sync(promptID: UnlockProtocol.manualPromptID, now: 103)
        _ = try gate.challenge(for: central, now: 103, nonce: nonce).get()
        failure(gate.authorize(prompt, from: central, now: 103, eligible: true), .unavailable)
    }

    func testManualFailuresCountSeparatelyAndResetOnlyWhenUnlocked() throws {
        let gate = UnlockGate(key: key)
        gate.sync(promptID: UnlockProtocol.manualPromptID, now: 100)
        for n in 0..<3 {
            var request = try command(gate, now: 101 + Double(n))
            request[21] ^= 1
            failure(gate.authorize(request, from: central, now: 101 + Double(n), eligible: true), .invalidSignature)
        }
        XCTAssertEqual(gate.manualFailures, 3)
        XCTAssertEqual(gate.failures, 0)
        XCTAssertThrowsError(try gate.challenge(for: central, now: 105).get())
        // 手机断开再连回（报告不新鲜了一会儿）不清零
        gate.sync(promptID: nil, now: 106)
        gate.sync(promptID: UnlockProtocol.manualPromptID, now: 107)
        XCTAssertThrowsError(try gate.challenge(for: central, now: 107).get())
        // 请提示照样能解
        gate.sync(promptID: 0x1234, now: 108)
        XCTAssertNoThrow(try gate.challenge(for: central, now: 108, nonce: nonce).get())
        // 电脑解锁过一次以后清零
        gate.sync(promptID: nil, now: 109)
        gate.resetManualFailures()
        gate.sync(promptID: UnlockProtocol.manualPromptID, now: 110)
        XCTAssertNoThrow(try gate.challenge(for: central, now: 110, nonce: nonce).get())
    }

    func testManualExecutionFailureCounts() throws {
        let gate = UnlockGate(key: key)
        gate.sync(promptID: UnlockProtocol.manualPromptID, now: 100)
        try gate.authorize(try command(gate), from: central, now: 101, eligible: true).get()
        XCTAssertThrowsError(try gate.challenge(for: central, now: 101).get(), "正在执行时不给新挑战")
        gate.finish(succeeded: false)
        XCTAssertEqual(gate.manualFailures, 1)
    }

    func testLockCommandVectorAndGate() throws {
        let vectorKey = UnlockKey(id: 0x78563412, secret: Data(0..<32))
        let packet = try XCTUnwrap(LockProtocol.command(key: vectorKey, reportNonce: nonce, seq: 0x11223344,
                                                        packetNonce: Data(0..<8)))
        // Python hmac.new(secret, b'lock-v1'+reportNonce+前 16 字节, sha256) 独立算的，和 App 一致
        XCTAssertEqual(packet.map { String(format: "%02x", $0) }.joined(),
                       "12345678443322110001020304050607442b75904bb993b827ddb143ec6926a8")
        XCTAssertEqual(LockProtocol.sequence(packet), 0x11223344)

        func accept(_ gate: LockGate, _ data: Data, sentAt: Double? = 100, now: Double = 101) -> ReportAuthenticationFailure? {
            if case .failure(let reason) = gate.accept(data, sentAt: sentAt, now: now, currentInterval: 1) { return reason }
            return nil
        }
        let gate = LockGate(key: vectorKey, reportNonce: nonce)
        XCTAssertEqual(accept(gate, packet, sentAt: nil), .staleHeartbeat, "电脑没发过这条 seq")
        XCTAssertEqual(accept(gate, packet, sentAt: 100, now: 110.01), .staleHeartbeat)
        XCTAssertNil(accept(gate, packet))
        XCTAssertEqual(accept(gate, packet, now: 102), .replay)
        var tampered = try XCTUnwrap(LockProtocol.command(key: vectorKey, reportNonce: nonce, seq: 0x11223344,
                                                          packetNonce: Data(repeating: 1, count: 8)))
        tampered[31] ^= 1
        XCTAssertEqual(accept(gate, tampered), .invalidSignature)
        XCTAssertEqual(accept(gate, Data(packet.dropLast())), .invalidFormat)
        let otherKey = try XCTUnwrap(LockProtocol.command(key: key, reportNonce: nonce, seq: 1, packetNonce: Data(0..<8)))
        XCTAssertEqual(accept(gate, otherKey), .wrongKey)
        // 换了电脑端进程（reportNonce 变了），旧包不认
        let otherSession = LockGate(key: vectorKey, reportNonce: Data(repeating: 0, count: 16))
        XCTAssertEqual(accept(otherSession, packet), .invalidSignature)
    }
}
