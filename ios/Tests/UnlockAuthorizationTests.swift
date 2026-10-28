import Foundation

/// 独立于 UIKit/蓝牙的互操作检查；只使用公开测试向量，不访问真实钥匙串条目。
@main
struct UnlockAuthorizationTests {
    static func main() throws {
        precondition(UnlockCapability.supports(platform: "darwin", capability: "ax-hmac-v3"))
        precondition(UnlockCapability.supports(platform: "win32", capability: "win-hmac-v3"))
        for (platform, capability) in [
            ("darwin", "win-hmac-v3"), ("win32", "ax-hmac-v3"),
            ("linux", "win-hmac-v3"), ("win32", "win-hmac-v2"),
            ("win32", "win-hmac-v4"), ("win32", "win-hmac-v3-extra"),
            ("WIN32", "win-hmac-v3"), ("darwin", "AX-HMAC-V3"),
        ] {
            precondition(!UnlockCapability.supports(platform: platform, capability: capability))
        }
        precondition(!UnlockCapability.supports(platform: nil, capability: "win-hmac-v3"))
        precondition(!UnlockCapability.supports(platform: "win32", capability: nil))
        precondition(!UnlockCapability.supports(platform: nil, capability: nil))

        let secret = Data((0..<32).map(UInt8.init))
        let enrollment = UnlockEnrollment(version: 1, keyID: 0x78563412, secret: secret)
        let json = String(decoding: try JSONEncoder().encode(enrollment), as: UTF8.self)
        let parsed = try UnlockEnrollment.parse("\n" + json + "\n")
        precondition(parsed == enrollment)

        var challenge = Data([0x34, 0x12])
        challenge.append(contentsOf: (0..<16).map(UInt8.init))
        let request = try enrollment.request(challenge: challenge, expectedPromptID: 0x1234)
        // Python hmac.new(bytes(range(32)), b'unlock-v2'+bytes([0x34,0x12])+bytes(range(16)), sha256)
        let expected = "1234567834124b78d367ade22f9aee438984eccfd654"
        precondition(request.map { String(format: "%02x", $0) }.joined() == expected)
        precondition(request.count == 22)

        try rejected { _ = try enrollment.request(challenge: challenge, expectedPromptID: 0x1235) }
        try rejected { _ = try enrollment.request(challenge: Data(challenge.dropLast()), expectedPromptID: 0x1234) }
        try rejected { _ = try enrollment.request(challenge: challenge + Data([0]), expectedPromptID: 0x1234) }
        try rejected { _ = try enrollment.request(challenge: Data(repeating: 0, count: 18), expectedPromptID: 0) }
        try rejected { _ = try UnlockEnrollment.parse("{\"version\":2,\"keyID\":1,\"secret\":\"\(secret.base64EncodedString())\"}") }
        try rejected { _ = try UnlockEnrollment.parse("{\"version\":1,\"keyID\":1,\"secret\":\"\(secret.dropLast().base64EncodedString())\"}") }
        try rejected { _ = try UnlockEnrollment.parse("invalid") }

        var otherNonce = challenge
        otherNonce[otherNonce.count - 1] ^= 1
        let changedRequest = try enrollment.request(challenge: otherNonce, expectedPromptID: 0x1234)
        precondition(changedRequest != request)

        let base = Data([0x04, 0x03, 0x02, 0x01, 0xc4, 0x02, 0x02])
        let sessionNonce = Data((0..<16).map(UInt8.init))
        let packetNonce = Data((0..<8).map(UInt8.init))
        let authenticated = try enrollment.authenticatedReport(base: base, sessionNonce: sessionNonce, packetNonce: packetNonce)
        // 独立 Python hmac.new(secret, b'proximity-report-v1'+sessionNonce+base+keyID_LE+packetNonce, sha256)
        let reportExpected = "04030201c40202123456780001020304050607fe75e30883ae3552ab7196d247dfdab9"
        precondition(authenticated.count == 35)
        precondition(authenticated.map { String(format: "%02x", $0) }.joined() == reportExpected)

        var changedBase = base
        changedBase[4] ^= 1
        let changedReport = try enrollment.authenticatedReport(base: changedBase, sessionNonce: sessionNonce, packetNonce: packetNonce)
        precondition(changedReport.suffix(16) != authenticated.suffix(16), "RSSI is authenticated")
        var newSession = sessionNonce
        newSession[0] ^= 1
        let newSessionReport = try enrollment.authenticatedReport(base: base, sessionNonce: newSession, packetNonce: packetNonce)
        precondition(newSessionReport.prefix(19) == authenticated.prefix(19))
        precondition(newSessionReport.suffix(16) != authenticated.suffix(16), "Report cannot cross host sessions")
        let attempt = AutomaticUnlockAttempt(session: sessionNonce.base64EncodedString(), promptID: 1)
        let sameAttempt = AutomaticUnlockAttempt(session: sessionNonce.base64EncodedString(), promptID: 1)
        let restartedHostAttempt = AutomaticUnlockAttempt(session: newSession.base64EncodedString(), promptID: 1)
        let nextPromptAttempt = AutomaticUnlockAttempt(session: sessionNonce.base64EncodedString(), promptID: 2)
        precondition(attempt == sameAttempt, "Reconnect keeps the same automatic attempt identity")
        precondition(attempt != restartedHostAttempt, "A new host session may reuse the prompt number")
        precondition(attempt != nextPromptAttempt, "A new prompt in the same host session may be attempted")
        var newPacket = packetNonce
        newPacket[0] ^= 1
        let newPacketReport = try enrollment.authenticatedReport(base: base, sessionNonce: sessionNonce, packetNonce: newPacket)
        precondition(newPacketReport.suffix(16) != authenticated.suffix(16), "Packet nonce is authenticated")
        try rejected { _ = try enrollment.authenticatedReport(base: Data(base.dropLast()), sessionNonce: sessionNonce, packetNonce: packetNonce) }
        try rejected { _ = try enrollment.authenticatedReport(base: base, sessionNonce: Data(sessionNonce.dropLast()), packetNonce: packetNonce) }
        try rejected { _ = try enrollment.authenticatedReport(base: base, sessionNonce: sessionNonce, packetNonce: Data(packetNonce.dropLast())) }
        precondition(tryRandomNonce().count == 8)

        // 和 Windows 的 tests/test_win_unlock_protocol.py、docs/protocol.md「登记确认」同一个向量（openssl 核对过）
        let ack = try enrollment.enrollAck(reportNonce: sessionNonce)
        precondition(ack.map { String(format: "%02x", $0) }.joined() == "12345678e8a232851651af8c3a8c9efbbeb9ab78")
        let newSessionAck = try enrollment.enrollAck(reportNonce: newSession)
        precondition(newSessionAck != ack, "Enrollment ack cannot cross host sessions")
        try rejected { _ = try enrollment.enrollAck(reportNonce: Data(sessionNonce.dropLast())) }
        print("UnlockAuthorization: platform capability whitelist, unlock/report/enroll-ack HMAC vectors and negative/change checks passed")
    }

    private static func rejected(_ body: () throws -> Void) throws {
        do {
            try body()
            fatalError("Expected invalid enrollment/challenge to be rejected")
        } catch { }
    }

    private static func tryRandomNonce() -> Data {
        do { return try UnlockEnrollment.randomReportNonce() }
        catch { fatalError("Secure random report nonce failed") }
    }
}
