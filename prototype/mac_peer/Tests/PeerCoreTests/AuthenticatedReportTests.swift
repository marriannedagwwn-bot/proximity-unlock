import Foundation
import XCTest
@testable import PeerCore

final class AuthenticatedReportTests: XCTestCase {
    private let key = UnlockKey(id: 0x78563412, secret: Data(0..<32))
    private let session = Data(0..<16)
    private let nonce = Data(0..<8)

    private func base(seq: UInt32 = 0x01020304, rssi: Int8 = -60) -> Data {
        var data = Data()
        withUnsafeBytes(of: seq.littleEndian) { data.append(contentsOf: $0) }
        data.append(UInt8(bitPattern: rssi))
        data.append(contentsOf: [2, 2])
        return data
    }

    private func packet(seq: UInt32 = 0x01020304, rssi: Int8 = -60, nonce: Data? = nil) throws -> Data {
        try XCTUnwrap(AuthenticatedReportProtocol.sign(baseReport: base(seq: seq, rssi: rssi), key: key,
                                                      reportNonce: session, packetNonce: nonce ?? self.nonce))
    }

    private func gate(key: UnlockKey? = nil, session: Data? = nil) -> AuthenticatedReportGate {
        AuthenticatedReportGate(key: key ?? self.key, reportNonce: session ?? self.session, maximumInterval: 30)
    }

    func testIndependentSignedReportVector() throws {
        let data = try packet()
        // Python hmac/hashlib 独立计算的固定向量；也由 iPhone codec 验证。
        XCTAssertEqual(data.map { String(format: "%02x", $0) }.joined(),
                       "04030201c40202123456780001020304050607fe75e30883ae3552ab7196d247dfdab9")
        XCTAssertEqual(AuthenticatedReportProtocol.sequence(data), 0x01020304)
        XCTAssertEqual(try gate().accept(data, sentAt: 100, now: 101, currentInterval: 1).get(), base())
    }

    func testEveryChangedByteFailsAuthentication() throws {
        let valid = try packet()
        for index in valid.indices {
            var data = valid
            data[index] ^= 1
            XCTAssertThrowsError(try gate().accept(data, sentAt: 100, now: 101, currentInterval: 1).get(), "byte \(index)")
        }
    }

    func testAnotherKeyAndAnotherProcessSessionCannotAuthenticate() throws {
        let data = try packet()
        let otherKey = UnlockKey(id: key.id, secret: Data(repeating: 0xa5, count: 32))
        XCTAssertThrowsError(try gate(key: otherKey).accept(data, sentAt: 100, now: 101, currentInterval: 1).get())
        XCTAssertThrowsError(try gate(session: Data(repeating: 0xa5, count: 16))
            .accept(data, sentAt: 100, now: 101, currentInterval: 1).get())
    }

    func testUnknownFutureOrExpiredHeartbeatCannotAuthenticate() throws {
        let data = try packet()
        for sentAt: Double? in [nil, 102, 90.99] {
            XCTAssertThrowsError(try gate().accept(data, sentAt: sentAt, now: 101, currentInterval: 1).get())
        }
        XCTAssertNoThrow(try gate().accept(data, sentAt: 100, now: 135, currentInterval: 30).get())
        XCTAssertThrowsError(try gate().accept(data, sentAt: 100, now: 135.01, currentInterval: 30).get())
    }

    func testDuplicateIsRejectedButWakeReportWithNewPacketNonceIsAccepted() throws {
        let gate = gate()
        let first = try packet()
        let second = try packet(nonce: Data(repeating: 0xaa, count: 8))
        XCTAssertNoThrow(try gate.accept(first, sentAt: 100, now: 101, currentInterval: 1).get())
        XCTAssertThrowsError(try gate.accept(first, sentAt: 100, now: 102, currentInterval: 1).get())
        XCTAssertNoThrow(try gate.accept(second, sentAt: 100, now: 103, currentInterval: 1).get())
    }

    func testChangingHeartbeatTierCannotReenableReplay() throws {
        let gate = gate()
        let old = try packet()
        XCTAssertNoThrow(try gate.accept(old, sentAt: 100, now: 101, currentInterval: 1).get())
        // 快档中过了 10 秒，也要保留可能在慢档有效期内重放的包。
        let next = try packet(seq: 2)
        XCTAssertNoThrow(try gate.accept(next, sentAt: 111, now: 111, currentInterval: 1).get())
        XCTAssertThrowsError(try gate.accept(old, sentAt: 100, now: 112, currentInterval: 30).get())
    }

    func testUnsignedAndTamperedReportsCannotLockOrPrompt() throws {
        let sys = FakeSystem()
        let judge = Judge(config: JudgeConfig(), system: sys, started: sys.now)
        let gate = gate()
        var history: [(wall: Double, rssi: Int)] = []
        var lastReport: Double?
        var protocolVersion = 1
        var seq: UInt32 = 0
        func feed(_ data: Data) {
            sys.now += 1
            if case .success(let verified) = gate.accept(data, sentAt: sys.now, now: sys.now, currentInterval: 1),
               let report = Proto.parseReport(verified) {
                history.append((sys.now, report.rssi))
                lastReport = sys.now
                protocolVersion = report.appProto
            }
            judge.update(link: LinkSnapshot(hasClients: true, lastReportWall: lastReport,
                                             recent: history, appProto: protocolVersion), now: sys.now)
        }
        // 未登记中心伪造持续弱信号，不能成为第一次已收到手机报告，也不能触发锁屏。
        for _ in 0..<80 { seq += 1; feed(base(seq: seq, rssi: -90)) }
        XCTAssertNil(lastReport)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(protocolVersion, 1)
        XCTAssertEqual(sys.lockCalls, 0)
        // 真实手机签名弱信号后才可以判定离开。
        for _ in 0..<80 { seq += 1; feed(try packet(seq: seq, rssi: -90)) }
        XCTAssertTrue(sys.locked)
        XCTAssertFalse(judge.prompting)
        let authenticatedCount = history.count
        // 未认证中心的强信号不能把真实手机从远处“搬回”电脑前。
        for _ in 0..<15 { seq += 1; feed(base(seq: seq, rssi: -40)) }
        XCTAssertEqual(history.count, authenticatedCount)
        XCTAssertFalse(judge.prompting)
        // 相同真实密钥的强信号仍走原来的靠近判断。
        for _ in 0..<10 { seq += 1; feed(try packet(seq: seq, rssi: -40)) }
        XCTAssertTrue(judge.prompting)
    }

    func testMalformedEnvelopeAndNonceLengthsAreRejected() throws {
        let data = try packet()
        XCTAssertThrowsError(try gate().accept(base(), sentAt: 100, now: 101, currentInterval: 1).get())
        XCTAssertThrowsError(try gate().accept(data + Data([0]), sentAt: 100, now: 101, currentInterval: 1).get())
        XCTAssertNil(AuthenticatedReportProtocol.sign(baseReport: base(), key: key, reportNonce: Data([0]), packetNonce: nonce))
        XCTAssertNil(AuthenticatedReportProtocol.sign(baseReport: base(), key: key, reportNonce: session, packetNonce: Data([0])))
    }

    func testUnauthenticatedCentralCannotReserveOrConsumeChallenge() throws {
        let trusted = UUID()
        let stranger = UUID()
        let reports = gate()
        let unlock = UnlockGate(key: key)
        unlock.sync(promptID: 123, now: 100)
        _ = try reports.accept(packet(), from: trusted, sentAt: 100, now: 101, currentInterval: 1).get()
        XCTAssertThrowsError(try reports.accept(base(), from: stranger, sentAt: 100, now: 101, currentInterval: 1).get())

        // 与 BLE 入口相同：先核对这个中心的在场证明，再触碰共享挑战，不能让无密钥中心抢占或消费。
        func read(_ central: UUID) -> Result<Data, UnlockStatus> {
            guard reports.isFresh(for: central, now: 101, currentInterval: 1) else { return .failure(.unavailable) }
            return unlock.challenge(for: central, now: 101)
        }
        func write(_ data: Data, _ central: UUID) -> Result<Void, UnlockStatus> {
            guard reports.isFresh(for: central, now: 101, currentInterval: 1) else { return .failure(.unavailable) }
            return unlock.authorize(data, from: central, now: 101, eligible: true)
        }
        XCTAssertThrowsError(try read(stranger).get())
        let challenge = try XCTUnwrap(UnlockProtocol.parseChallenge(try read(trusted).get()))
        XCTAssertThrowsError(try read(stranger).get())
        XCTAssertThrowsError(try write(Data(), stranger).get())
        XCTAssertEqual(unlock.failures, 0)
        XCTAssertNoThrow(try write(UnlockProtocol.command(key: key, challenge: challenge), trusted).get())
    }

    func testDisconnectClearsOnlyThatCentralsPresenceAndReplayCannotRestoreIt() throws {
        let reports = gate()
        let first = UUID()
        let second = UUID()
        let firstPacket = try packet()
        _ = try reports.accept(firstPacket, from: first, sentAt: 100, now: 101, currentInterval: 1).get()
        _ = try reports.accept(packet(nonce: Data(repeating: 0x55, count: 8)), from: second,
                               sentAt: 100, now: 101, currentInterval: 1).get()
        reports.clearPresence(for: first)
        XCTAssertFalse(reports.isFresh(for: first, now: 102, currentInterval: 1))
        XCTAssertTrue(reports.isFresh(for: second, now: 102, currentInterval: 1))
        XCTAssertThrowsError(try reports.accept(firstPacket, from: first, sentAt: 100, now: 102, currentInterval: 1).get())
        XCTAssertFalse(reports.isFresh(for: first, now: 102, currentInterval: 1))
        _ = try reports.accept(packet(nonce: Data(repeating: 0xaa, count: 8)), from: first,
                               sentAt: 100, now: 102, currentInterval: 1).get()
        XCTAssertTrue(reports.isFresh(for: first, now: 102, currentInterval: 1))
        reports.clearAllPresence()
        XCTAssertFalse(reports.hasFreshReport(now: 102, currentInterval: 1))
    }

    func testCentralPresenceExpiresWithReportWindow() throws {
        let reports = gate()
        let central = UUID()
        XCTAssertFalse(reports.hasFreshReport(now: 101, currentInterval: 1))
        _ = try reports.accept(packet(), from: central, sentAt: 100, now: 101, currentInterval: 1).get()
        XCTAssertTrue(reports.hasFreshReport(now: 111, currentInterval: 1))
        XCTAssertFalse(reports.isFresh(for: central, now: 111.01, currentInterval: 1))
        XCTAssertTrue(reports.isFresh(for: central, now: 136, currentInterval: 30))
        XCTAssertFalse(reports.isFresh(for: central, now: 136.01, currentInterval: 30))
        XCTAssertFalse(reports.isFresh(for: central, now: 100, currentInterval: 1))
    }
}
