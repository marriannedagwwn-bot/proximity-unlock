import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// 只接受明确实现应用层 v3 的平台/能力组合，不按前缀或协议版本推断能力。
enum UnlockCapability {
    static func supports(platform: String?, capability: String?) -> Bool {
        switch (platform, capability) {
        case ("darwin", "ax-hmac-v3"), ("win32", "win-hmac-v3"): true
        default: false
        }
    }
}

/// 本机线下登记码只包含共享密钥，不包含电脑登录密码。密钥不通过蓝牙登记。
struct UnlockEnrollment: Codable, Equatable {
    let version: Int
    let keyID: UInt32
    let secret: Data

    static func parse(_ text: String) throws -> UnlockEnrollment {
        let bytes = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard bytes.count <= 2048,
              let value = try? JSONDecoder().decode(UnlockEnrollment.self, from: bytes),
              value.version == 1, value.secret.count == 32 else {
            throw UnlockAuthorizationError.invalidEnrollment
        }
        return value
    }

    func request(challenge: Data, expectedPromptID: UInt16) throws -> Data {
        guard secret.count == 32, challenge.count == 18 else {
            throw UnlockAuthorizationError.invalidChallenge
        }
        let bytes = [UInt8](challenge)
        let promptID = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard promptID != 0, promptID == expectedPromptID else {
            throw UnlockAuthorizationError.stalePrompt
        }
        var message = Data("unlock-v2".utf8)
        message.append(challenge)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        var payload = Data()
        var id = keyID.littleEndian
        withUnsafeBytes(of: &id) { payload.append(contentsOf: $0) }
        payload.append(challenge.prefix(2))
        payload.append(contentsOf: signature.prefix(16))
        return payload
    }

    /// v3 的 REPORT 认证扩展。会话 nonce 来自本次电脑进程的 INFO；每包另有独立随机数。
    func authenticatedReport(base: Data, sessionNonce: Data, packetNonce: Data) throws -> Data {
        guard secret.count == 32, base.count == 7, sessionNonce.count == 16, packetNonce.count == 8 else {
            throw UnlockAuthorizationError.invalidReport
        }
        var payload = base
        var id = keyID.littleEndian
        withUnsafeBytes(of: &id) { payload.append(contentsOf: $0) }
        payload.append(packetNonce)
        var message = Data("proximity-report-v1".utf8)
        message.append(sessionNonce)
        message.append(payload)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        payload.append(contentsOf: signature.prefix(16))
        return payload
    }

    /// 登记确认（ENROLL_ACK，docs/protocol.md「登记确认」）：告诉电脑这部手机已经保存了这份登记，电脑的登记窗口收到就自己关。
    /// 20 字节：keyID（小端）+ HMAC(secret, "enroll-ack-v1" ‖ reportNonce ‖ keyID 小端) 的前 16 字节。
    /// 绑定这条连接 INFO 的 reportNonce，只用来关窗口，不算在场、不能解锁
    func enrollAck(reportNonce: Data) throws -> Data {
        guard secret.count == 32, reportNonce.count == 16 else {
            throw UnlockAuthorizationError.invalidReport
        }
        var id = Data()
        var littleEndian = keyID.littleEndian
        withUnsafeBytes(of: &littleEndian) { id.append(contentsOf: $0) }
        var message = Data("enroll-ack-v1".utf8)
        message.append(reportNonce)
        message.append(id)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return id + Data(signature.prefix(16))
    }

    static func randomReportNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw UnlockAuthorizationError.randomnessUnavailable
        }
        return Data(bytes)
    }
}

enum UnlockAuthorizationError: LocalizedError {
    case invalidEnrollment
    case invalidChallenge
    case stalePrompt
    case invalidReport
    case randomnessUnavailable
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEnrollment: "登记码无效，请重新从这台电脑的本机设置中复制。"
        case .invalidChallenge: "电脑返回的解锁挑战无效，本次请求已停止。"
        case .stalePrompt: "这次解锁提示已过期，请等待电脑发出新的提示。"
        case .invalidReport: "电脑的报告认证信息无效，自动解锁暂不可用。"
        case .randomnessUnavailable: "无法生成报告认证所需的随机数，自动解锁暂不可用。"
        case .keychain(let status):
            status == errSecInteractionNotAllowed
                ? "手机重启后需要先解锁一次，才能使用解锁登记。"
                : "无法访问解锁登记（钥匙串错误 \(status)）。"
        }
    }
}

/// 仅以添加电脑时固定的 key 索引；电脑更换蓝牙 identifier 后登记仍属于原来的电脑。
enum UnlockKeychain {
    // 沿用已有 service，保留升级前的 Mac 登记；各电脑仍由独立 UUID 隔离。
    private static let service = "proximity-unlock.mac-unlock.v1"

    private static func query(_ computer: UUID) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: computer.uuidString,
                kSecUseAuthenticationContext as String: context]
    }

    /// 只查存在性，不读密钥；手机锁着时也能决定通知是否提供用户确认动作。
    static func contains(_ computer: UUID) -> Bool {
        let status = SecItemCopyMatching(query(computer) as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func load(_ computer: UUID) throws -> UnlockEnrollment? {
        var q = query(computer)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw UnlockAuthorizationError.keychain(status) }
        guard let data = result as? Data,
              let enrollment = try? JSONDecoder().decode(UnlockEnrollment.self, from: data),
              enrollment.version == 1, enrollment.secret.count == 32 else {
            throw UnlockAuthorizationError.invalidEnrollment
        }
        return enrollment
    }

    static func save(_ enrollment: UnlockEnrollment, for computer: UUID) throws {
        guard enrollment.version == 1, enrollment.secret.count == 32 else {
            throw UnlockAuthorizationError.invalidEnrollment
        }
        let data = try JSONEncoder().encode(enrollment)
        let q = query(computer)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw UnlockAuthorizationError.keychain(added) }
        } else if status != errSecSuccess {
            throw UnlockAuthorizationError.keychain(status)
        }
    }

    static func delete(_ computer: UUID) throws {
        let status = SecItemDelete(query(computer) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw UnlockAuthorizationError.keychain(status)
        }
    }
}

/// reportNonce 是公开会话标识；同编号在电脑端重启后的新会话里是不同提示。
struct AutomaticUnlockAttempt: Codable, Equatable {
    let session: String
    let promptID: UInt16
}

/// 仅保存开关和已尝试提示的会话/编号；共享密钥始终只在钥匙串中。
enum UnlockPreferences {
    static func automaticEnabled(_ computer: UUID, enrolled: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: "unlock.auto.enabled.\(computer.uuidString)") as? Bool) ?? enrolled
    }

    static func setAutomatic(_ enabled: Bool, for computer: UUID) {
        UserDefaults.standard.set(enabled, forKey: "unlock.auto.enabled.\(computer.uuidString)")
    }

    static func lastAutomaticAttempt(_ computer: UUID) -> AutomaticUnlockAttempt? {
        guard let data = UserDefaults.standard.data(forKey: "unlock.auto.attempt.v3.\(computer.uuidString)") else { return nil }
        return try? JSONDecoder().decode(AutomaticUnlockAttempt.self, from: data)
    }

    static func markAutomaticAttempt(_ attempt: AutomaticUnlockAttempt, for computer: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(attempt) else { return false }
        UserDefaults.standard.set(data, forKey: "unlock.auto.attempt.v3.\(computer.uuidString)")
        // 提交蓝牙命令前把去重标记写稳，避免 App 紧接着退出导致同一提示再次自动执行。
        return UserDefaults.standard.synchronize()
    }
}
