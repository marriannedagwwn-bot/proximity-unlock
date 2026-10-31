import CryptoKit
import Foundation

/// 离线登记的设备密钥；只在本机钥匙串及手机钥匙串保存，不通过蓝牙发送。
public struct UnlockKey: Codable, Equatable {
    public let id: UInt32
    public let secret: Data

    public init(id: UInt32, secret: Data) {
        self.id = id
        self.secret = secret
    }
}

/// 已登记手机请求解锁的应用层协议。固定长度、小端；与 iPhone 实现保持一致。
public enum UnlockProtocol {
    public static let challengeUUID = "0c28c82e-69ec-4cd1-ab3b-ea7e160fcd3c"
    public static let commandUUID = "54cd9a6f-36e3-4c39-b875-bbeee5f1aef1"
    public static let capability = "ax-hmac-v3"
    public static let challengeLength = 18
    public static let commandLength = 22
    /// 手动解锁（docs/protocol.md「手动锁屏、解锁」）：电脑锁着、没在请提示时，挑战里的提示编号是 0。
    /// 签名消息和按提示解锁一样，编号 0 的签名不能拿去解别的提示，反过来也一样
    public static let manualPromptID: UInt16 = 0
    /// 手动解锁的随机数从发出起多少秒有效（按提示解锁是从提示起 120 秒）
    public static let manualLifetime = 30.0
    /// INFO 里的 `manual`：电脑端支持手动解锁和手机锁屏
    public static let manualVersion = 1

    public struct Challenge: Equatable {
        public let promptID: UInt16
        public let nonce: Data

        public init(promptID: UInt16, nonce: Data) {
            self.promptID = promptID
            self.nonce = nonce
        }

        public var data: Data {
            var data = Data()
            withUnsafeBytes(of: promptID.littleEndian) { data.append(contentsOf: $0) }
            data.append(nonce)
            return data
        }
    }

    public static func parseChallenge(_ data: Data) -> Challenge? {
        guard data.count == challengeLength else { return nil }
        let bytes = [UInt8](data)
        return Challenge(promptID: UInt16(bytes[0]) | UInt16(bytes[1]) << 8,
                         nonce: Data(bytes[2..<18]))
    }

    public static func randomNonce() -> Data {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    public static func tag(key: UnlockKey, challenge: Challenge) -> Data {
        var message = Data("unlock-v2".utf8)
        message.append(challenge.data)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key.secret))
        return Data(code.prefix(16))
    }

    public static func command(key: UnlockKey, challenge: Challenge) -> Data {
        var data = Data()
        withUnsafeBytes(of: key.id.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: challenge.promptID.littleEndian) { data.append(contentsOf: $0) }
        data.append(tag(key: key, challenge: challenge))
        return data
    }
}

/// ATT 的应用错误值（0x80 起）；不把认证细节或凭据写到蓝牙回复里。
public enum UnlockStatus: UInt8, Error, Equatable {
    case unavailable = 0x80
    case invalidSignature = 0x81
    case invalidChallenge = 0x82
    case executionFailed = 0x83
}

/// 纯逻辑认证门禁。蓝牙 delegate 和完成回调都在主队列调用，不跨线程共享。
/// 每次提示最多三次失败；每个随机数只能核对一次，且只接受读它的那台手机。
/// 编号 0 是手动解锁（电脑锁着、没在请提示，手机用户在 App 里点了解锁）：随机数从发出起 manualLifetime 秒有效，
/// 失败次数另算，每次锁屏最多三次，解锁以后（resetManualFailures）才清零
public final class UnlockGate {
    private struct Pending {
        let challenge: UnlockProtocol.Challenge
        let central: UUID
        /// 发出的时间，手动解锁按它算有效期
        let issued: Double
    }

    private let key: UnlockKey
    private let lifetime: Double
    private let maximumFailures: Int
    private var promptID: UInt16?
    private var lastPromptID: UInt16?
    private var promptStarted: Double?
    private var pending: Pending?
    private var authorizingPromptID: UInt16?
    public private(set) var failures = 0
    public private(set) var manualFailures = 0
    public private(set) var inFlight = false

    public init(key: UnlockKey, lifetime: Double = 120, maximumFailures: Int = 3) {
        self.key = key
        self.lifetime = lifetime
        self.maximumFailures = maximumFailures
    }

    /// nil 表示提示已撤销、系统没锁着，或用户关闭了真实锁屏；0 是手动解锁。立即令未用的随机数失效。
    public func sync(promptID: UInt16?, now: Double) {
        guard self.promptID != promptID else { return }
        self.promptID = promptID
        pending = nil
        if let promptID, promptID != UnlockProtocol.manualPromptID, promptID != lastPromptID {
            promptStarted = now
            failures = 0
            lastPromptID = promptID
        }
        // 已经交给系统执行的操作必须等待完成；提示变更不能启动第二次并发解锁。
    }

    /// 电脑解锁了：下一次锁屏重新算手动解锁的失败次数。只在真的解锁时调，手机断开再连回不清
    public func resetManualFailures() {
        manualFailures = 0
    }

    public func challenge(for central: UUID, now: Double,
                          nonce: Data = UnlockProtocol.randomNonce()) -> Result<Data, UnlockStatus> {
        guard let promptID, key.secret.count == 32, now.isFinite,
              !inFlight, !exhausted else { return .failure(.unavailable) }
        let manual = promptID == UnlockProtocol.manualPromptID
        if !manual {
            guard validTime(now) else {
                pending = nil
                return .failure(.invalidChallenge)
            }
        }
        if let pending {
            if manual && !fresh(pending, now: now) {
                self.pending = nil  // 手动解锁的随机数过期了，换一个新的
            } else {
                guard pending.central == central else { return .failure(.unavailable) }
                return .success(pending.challenge.data)
            }
        }
        guard nonce.count == 16 else { return .failure(.invalidChallenge) }
        let value = UnlockProtocol.Challenge(promptID: promptID, nonce: nonce)
        pending = Pending(challenge: value, central: central, issued: now)
        return .success(value.data)
    }

    /// eligible 由调用方实时核对：电脑仍然锁着、正在提示同一编号（手动解锁是没在提示），且显式启用了真实锁屏和解锁登记。
    /// 成功后占住 inFlight，调用方执行一次系统解锁，再调用 finish()；任何失败都不能自动重试。
    public func authorize(_ data: Data, from central: UUID, now: Double,
                          eligible: Bool) -> Result<Void, UnlockStatus> {
        guard eligible else {
            pending = nil
            return .failure(.unavailable)
        }
        guard let promptID, !inFlight, !exhausted else {
            return .failure(.unavailable)
        }
        guard let pending else { return failed(.invalidChallenge) }
        // 核对一次就消费，包括错误设备、错误编号、格式错误和签名错误。
        self.pending = nil
        let manual = promptID == UnlockProtocol.manualPromptID
        guard manual ? fresh(pending, now: now) : validTime(now) else { return failed(.invalidChallenge) }
        guard pending.central == central else { return failed(.unavailable) }
        guard data.count == UnlockProtocol.commandLength else { return failed(.invalidSignature) }
        let bytes = [UInt8](data)
        let keyID = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let requestPrompt = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        guard keyID == key.id, requestPrompt == promptID else { return failed(.unavailable) }
        let expected = UnlockProtocol.tag(key: key, challenge: pending.challenge)
        let supplied = bytes[6..<22]
        // 固定长度比较，避免在第一个不匹配字节就返回。
        let difference = zip(expected, supplied).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { return failed(.invalidSignature) }
        inFlight = true
        authorizingPromptID = promptID
        return .success(())
    }

    public func finish(succeeded: Bool = true) {
        if inFlight && !succeeded && promptID == authorizingPromptID { countFailure() }
        inFlight = false
        pending = nil
        authorizingPromptID = nil
    }

    private var exhausted: Bool {
        (promptID == UnlockProtocol.manualPromptID ? manualFailures : failures) >= maximumFailures
    }

    private func countFailure() {
        if promptID == UnlockProtocol.manualPromptID { manualFailures += 1 } else { failures += 1 }
    }

    private func validTime(_ now: Double) -> Bool {
        guard let promptStarted, now.isFinite, promptStarted.isFinite else { return false }
        return now >= promptStarted && now - promptStarted <= lifetime
    }

    private func fresh(_ pending: Pending, now: Double) -> Bool {
        now.isFinite && now >= pending.issued && now - pending.issued <= UnlockProtocol.manualLifetime
    }

    private func failed(_ status: UnlockStatus) -> Result<Void, UnlockStatus> {
        countFailure()
        return .failure(status)
    }
}

/// 手机让电脑锁屏（docs/protocol.md「手动锁屏、解锁」）。32 字节：keyID、手机收到的最近一次心跳 seq（小端）、
/// 每包随机数 8 字节、HMAC-SHA256(secret, "lock-v1" ‖ reportNonce ‖ 前 16 字节) 的前 16 字节。
/// 和认证报告一样靠「电脑真发过、没过期的心跳 seq」和不重放挡旧包，不用先读挑战
public enum LockProtocol {
    public static let uuid = "10c0be5d-68ca-44bd-87ce-a2e42e9604da"
    public static let length = 32

    public static func sequence(_ data: Data) -> UInt32? {
        guard data.count == length else { return nil }
        let b = [UInt8](data)
        return UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
    }

    public static func command(key: UnlockKey, reportNonce: Data, seq: UInt32, packetNonce: Data) -> Data? {
        guard key.secret.count == 32, reportNonce.count == 16, packetNonce.count == 8 else { return nil }
        var prefix = Data()
        withUnsafeBytes(of: key.id.littleEndian) { prefix.append(contentsOf: $0) }
        withUnsafeBytes(of: seq.littleEndian) { prefix.append(contentsOf: $0) }
        prefix.append(packetNonce)
        return prefix + tag(key: key, reportNonce: reportNonce, prefix: prefix)
    }

    static func tag(key: UnlockKey, reportNonce: Data, prefix: Data) -> Data {
        var message = Data("lock-v1".utf8)
        message.append(reportNonce)
        message.append(prefix)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key.secret)).prefix(16))
    }
}

/// 锁屏命令的门禁：密钥、签名、心跳 seq 新鲜度、不重放。锁屏只会让电脑更安全，所以不要挑战、不限失败次数
public final class LockGate {
    private let key: UnlockKey
    private let reportNonce: Data
    private let maximumInterval: Double
    private var seenTags: [Data: Double] = [:]

    public init(key: UnlockKey, reportNonce: Data, maximumInterval: Double = 30) {
        self.key = key
        self.reportNonce = reportNonce
        self.maximumInterval = maximumInterval
    }

    /// sentAt：电脑发出这条 seq 心跳的时间（本次进程真实发过的心跳表），now 用同一个时钟
    public func accept(_ data: Data, sentAt: Double?, now: Double,
                       currentInterval: Double) -> Result<Void, ReportAuthenticationFailure> {
        guard key.secret.count == 32, reportNonce.count == 16, now.isFinite,
              currentInterval.isFinite, currentInterval >= 0, currentInterval <= maximumInterval else {
            return .failure(.invalidConfiguration)
        }
        seenTags = seenTags.filter { now - $0.value <= max(10, maximumInterval + 5) }
        guard data.count == LockProtocol.length else { return .failure(.invalidFormat) }
        let bytes = [UInt8](data)
        let keyID = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        guard keyID == key.id else { return .failure(.wrongKey) }
        guard let sentAt, sentAt.isFinite, now >= sentAt,
              now - sentAt <= max(10, currentInterval + 5) else { return .failure(.staleHeartbeat) }
        let expected = LockProtocol.tag(key: key, reportNonce: reportNonce, prefix: Data(bytes[0..<16]))
        let supplied = Data(bytes[16..<32])
        let difference = zip(expected, supplied).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { return .failure(.invalidSignature) }
        guard seenTags[supplied] == nil else { return .failure(.replay) }
        seenTags[supplied] = now
        return .success(())
    }
}

/// v3 的认证信号报告。随机会话 nonce 来自 INFO；它不是密钥，每次电脑端启动都不同。
public enum AuthenticatedReportProtocol {
    public static let packetLength = 35

    public static func sequence(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    /// baseReport=7 字节 REPORT；packetNonce 每包随机 8 字节，同一次心跳的主动报告也必须换 nonce。
    public static func sign(baseReport: Data, key: UnlockKey, reportNonce: Data, packetNonce: Data) -> Data? {
        guard baseReport.count == 7, key.secret.count == 32, reportNonce.count == 16, packetNonce.count == 8 else {
            return nil
        }
        var prefix = baseReport
        withUnsafeBytes(of: key.id.littleEndian) { prefix.append(contentsOf: $0) }
        prefix.append(packetNonce)
        var message = Data("proximity-report-v1".utf8)
        message.append(reportNonce)
        message.append(prefix)
        let tag = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key.secret))
        prefix.append(contentsOf: tag.prefix(16))
        return prefix
    }
}

public enum ReportAuthenticationFailure: Error, Equatable {
    case invalidFormat, wrongKey, invalidSignature, staleHeartbeat, replay, invalidConfiguration
}

/// 已启用自动解锁时，只有认证成功的报告才能进入判断状态机。
/// replay 缓存保留配置中最长间隔的有效期，不能在切回快档时提前丢掉，免得再次变慢后旧包重新有效。
public final class AuthenticatedReportGate {
    private let key: UnlockKey
    private let reportNonce: Data
    private let maximumInterval: Double
    private var seenTags: [Data: Double] = [:]
    private var verifiedCentrals: [UUID: Double] = [:]

    public init(key: UnlockKey, reportNonce: Data, maximumInterval: Double = 30) {
        self.key = key
        self.reportNonce = reportNonce
        self.maximumInterval = maximumInterval
    }

    /// sentAt 必须来自本次进程真实发过的心跳表；now/sentAt 使用同一时钟。
    /// 失败时只返回原因，不返回可误用为信号的任何部分。
    public func accept(_ data: Data, from central: UUID? = nil, sentAt: Double?, now: Double,
                       currentInterval: Double) -> Result<Data, ReportAuthenticationFailure> {
        guard key.secret.count == 32, reportNonce.count == 16,
              now.isFinite, maximumInterval.isFinite, maximumInterval >= 0,
              currentInterval.isFinite, currentInterval >= 0, currentInterval <= maximumInterval else {
            return .failure(.invalidConfiguration)
        }
        let retention = max(10, maximumInterval + 5)
        seenTags = seenTags.filter { now - $0.value <= retention }
        guard data.count == AuthenticatedReportProtocol.packetLength else { return .failure(.invalidFormat) }
        let bytes = [UInt8](data)
        let keyID = UInt32(bytes[7]) | UInt32(bytes[8]) << 8 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 24
        guard keyID == key.id else { return .failure(.wrongKey) }
        guard let sentAt, sentAt.isFinite, now >= sentAt,
              now - sentAt <= max(10, currentInterval + 5) else { return .failure(.staleHeartbeat) }
        let prefix = Data(bytes[0..<19])
        var message = Data("proximity-report-v1".utf8)
        message.append(reportNonce)
        message.append(prefix)
        let expected = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key.secret)).prefix(16)
        let supplied = Data(bytes[19..<35])
        let difference = zip(expected, supplied).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { return .failure(.invalidSignature) }
        guard seenTags[supplied] == nil else { return .failure(.replay) }
        seenTags[supplied] = sentAt
        if let central { verifiedCentrals[central] = now }
        return .success(Data(bytes[0..<7]))
    }

    public func isFresh(for central: UUID, now: Double, currentInterval: Double) -> Bool {
        verifiedCentrals[central].map { fresh($0, now: now, currentInterval: currentInterval) } ?? false
    }

    public func hasFreshReport(now: Double, currentInterval: Double) -> Bool {
        verifiedCentrals.values.contains { fresh($0, now: now, currentInterval: currentInterval) }
    }

    /// 订阅代际变更时清除设备在场证明；不能沿用上一次连接的报告抢占本次挑战。
    public func clearPresence(for central: UUID) {
        verifiedCentrals.removeValue(forKey: central)
    }

    public func clearAllPresence() {
        verifiedCentrals.removeAll()
    }

    private func fresh(_ time: Double, now: Double, currentInterval: Double) -> Bool {
        guard now.isFinite, time.isFinite, currentInterval.isFinite,
              currentInterval >= 0, currentInterval <= maximumInterval else { return false }
        return now >= time && now - time <= max(10, currentInterval + 5)
    }
}
