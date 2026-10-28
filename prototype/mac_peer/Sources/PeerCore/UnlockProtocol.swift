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
public final class UnlockGate {
    private struct Pending {
        let challenge: UnlockProtocol.Challenge
        let central: UUID
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
    public private(set) var inFlight = false

    public init(key: UnlockKey, lifetime: Double = 120, maximumFailures: Int = 3) {
        self.key = key
        self.lifetime = lifetime
        self.maximumFailures = maximumFailures
    }

    /// nil 表示提示已撤销、系统没锁着，或用户关闭了真实锁屏。立即令未用的随机数失效。
    public func sync(promptID: UInt16?, now: Double) {
        guard self.promptID != promptID else { return }
        self.promptID = promptID
        pending = nil
        if let promptID, promptID != lastPromptID {
            promptStarted = now
            failures = 0
            lastPromptID = promptID
        }
        // 已经交给系统执行的操作必须等待完成；提示变更不能启动第二次并发解锁。
    }

    public func challenge(for central: UUID, now: Double,
                          nonce: Data = UnlockProtocol.randomNonce()) -> Result<Data, UnlockStatus> {
        guard let promptID, promptID != 0, key.secret.count == 32,
              !inFlight, failures < maximumFailures else { return .failure(.unavailable) }
        guard validTime(now) else {
            pending = nil
            return .failure(.invalidChallenge)
        }
        if let pending {
            guard pending.central == central else { return .failure(.unavailable) }
            return .success(pending.challenge.data)
        }
        guard nonce.count == 16 else { return .failure(.invalidChallenge) }
        let value = UnlockProtocol.Challenge(promptID: promptID, nonce: nonce)
        pending = Pending(challenge: value, central: central)
        return .success(value.data)
    }

    /// eligible 由调用方实时核对：正在提示、电脑仍然锁着，且显式启用了真实锁屏和解锁登记。
    /// 成功后占住 inFlight，调用方执行一次系统解锁，再调用 finish()；任何失败都不能自动重试。
    public func authorize(_ data: Data, from central: UUID, now: Double,
                          eligible: Bool) -> Result<Void, UnlockStatus> {
        guard eligible else {
            pending = nil
            return .failure(.unavailable)
        }
        guard let promptID, !inFlight, failures < maximumFailures else {
            return .failure(.unavailable)
        }
        guard let pending else { return failed(.invalidChallenge) }
        // 核对一次就消费，包括错误设备、错误编号、格式错误和签名错误。
        self.pending = nil
        guard validTime(now) else { return failed(.invalidChallenge) }
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
        if inFlight && !succeeded && promptID == authorizingPromptID { failures += 1 }
        inFlight = false
        pending = nil
        authorizingPromptID = nil
    }

    private func validTime(_ now: Double) -> Bool {
        guard let promptStarted, now.isFinite, promptStarted.isFinite else { return false }
        return now >= promptStarted && now - promptStarted <= lifetime
    }

    private func failed(_ status: UnlockStatus) -> Result<Void, UnlockStatus> {
        failures += 1
        return .failure(status)
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
