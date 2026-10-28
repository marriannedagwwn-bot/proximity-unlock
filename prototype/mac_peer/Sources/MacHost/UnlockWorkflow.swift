import Foundation

/// 不接触系统 API 的解锁步骤；测试用假的 driver，不会锁屏或写入任何真实输入框。
struct UnlockSession: Equatable {
    let username: String
    let uid: UInt32
    let auditID: UInt32
}

struct UnlockPermissions {
    let accessibility: Bool
    let postEvents: Bool
}

protocol ScreenUnlockDriver: AnyObject {
    associatedtype Field: Equatable
    func permissions() -> UnlockPermissions
    func currentSession() -> UnlockSession?
    /// nil 是未知，绝不按已解锁处理。
    func lockedState() -> Bool?
    /// 只返回 loginwindow 中可写的安全密码框；其它焦点一律 nil。
    func focusedPasswordField() -> Field?
    func writeValue(_ value: String, to field: Field) throws
    /// AXValue 可能返回原始字符串，也可能返回掩码；只传长度，不向状态机传字段内容。
    func fieldLength(_ field: Field) -> Int?
    func pressKey(_ code: UInt16) async throws
    func monotonicTime() -> TimeInterval
    func pause(_ interval: TimeInterval) async throws
}

enum ScreenUnlockFailure: Error {
    case permissions, session, unlocked, unknownState, focus, fieldWrite, timeout, cancelled

    var note: String {
        switch self {
        case .permissions: return "需要辅助功能和发送系统事件权限"
        case .session: return "无法确认当前用户的控制台会话，已停止解锁"
        case .unlocked: return "屏幕锁定状态已变化，已停止输入"
        case .unknownState: return "无法确认真实锁屏状态，已停止解锁"
        case .focus: return "焦点不是当前登录界面的可写安全密码框，已停止输入"
        case .fieldWrite: return "登录界面的安全密码框无法写入"
        case .timeout: return "未在期限内确认系统解锁；没有自动重试密码"
        case .cancelled: return "解锁已取消"
        }
    }
}

actor ScreenUnlockWorkflow<Driver: ScreenUnlockDriver> {
    private let driver: Driver
    private var inFlight = false

    init(driver: Driver) { self.driver = driver }

    func unlock(password: String) async -> (ok: Bool, note: String) {
        guard !inFlight else { return (false, "已有一次解锁正在进行") }
        guard !password.isEmpty, !password.contains("\0"), password.utf8.count <= 16_384 else {
            return (false, "本机解锁凭据无效")
        }
        inFlight = true
        defer { inFlight = false }
        var session: UnlockSession?
        var field: Driver.Field?
        var inserted = false
        do {
            try Task.checkCancellation()
            let permission = driver.permissions()
            guard permission.accessibility && permission.postEvents else { throw ScreenUnlockFailure.permissions }
            guard let initialSession = driver.currentSession() else { throw ScreenUnlockFailure.session }
            session = initialSession
            try requireLockedSession(initialSession)
            // 点亮后 loginwindow 可能还在建立焦点。只等界面就绪，不用按键唤出它，也不重试密码。
            let initialField = try await waitForPasswordField(in: initialSession, timeout: 2)
            field = initialField

            // 只向已经核实的安全密码框发按键。关键是写 AXValue，密码不经过逐字键盘模拟。
            try requireField(initialField, in: initialSession)
            try await driver.pressKey(0x33) // Delete
            try await driver.pause(0.1)
            try requireField(initialField, in: initialSession)
            try driver.writeValue("", to: initialField)
            try await waitForLength([0], field: initialField, session: initialSession, timeout: 1)
            try requireField(initialField, in: initialSession)
            // AX 返回超时/失败也可能已经把请求送到目标进程；从尝试写入起就承担同焦点清理责任。
            inserted = true
            try driver.writeValue(password, to: initialField)
            // 不同安全文本框的掩码按字符、Unicode scalar 或 UTF-16 单元计数；原文始终作为 CFString 整体写入。
            let lengths: Set<Int> = [password.count, password.unicodeScalars.count, password.utf16.count]
            try await waitForLength(lengths, field: initialField, session: initialSession, timeout: 2)
            try requireField(initialField, in: initialSession)
            try await driver.pressKey(0x24) // Return；只提交一次，失败不能自动再试。

            let deadline = driver.monotonicTime() + 7
            while true {
                try Task.checkCancellation()
                guard driver.currentSession() == initialSession else { throw ScreenUnlockFailure.session }
                guard let locked = driver.lockedState() else { throw ScreenUnlockFailure.unknownState }
                if !locked { return (true, "已确认系统解锁") }
                guard driver.monotonicTime() < deadline else { throw ScreenUnlockFailure.timeout }
                try await driver.pause(min(0.1, deadline - driver.monotonicTime()))
            }
        } catch {
            // 失败后不留下自己写的内容；只清理同一会话、同一安全焦点，绝不追着新焦点写。
            if inserted, let field, let session,
               driver.currentSession() == session, driver.lockedState() == true,
               driver.focusedPasswordField() == field {
                try? driver.writeValue("", to: field)
            }
            if error is CancellationError { return (false, ScreenUnlockFailure.cancelled.note) }
            return (false, (error as? ScreenUnlockFailure ?? .fieldWrite).note)
        }
    }

    private func requireLockedSession(_ session: UnlockSession) throws {
        try Task.checkCancellation()
        guard driver.currentSession() == session else { throw ScreenUnlockFailure.session }
        guard let locked = driver.lockedState() else { throw ScreenUnlockFailure.unknownState }
        guard locked else { throw ScreenUnlockFailure.unlocked }
    }

    private func requireField(_ field: Driver.Field, in session: UnlockSession) throws {
        try requireLockedSession(session)
        let permission = driver.permissions()
        guard permission.accessibility && permission.postEvents else { throw ScreenUnlockFailure.permissions }
        guard driver.focusedPasswordField() == field else { throw ScreenUnlockFailure.focus }
    }

    private func waitForPasswordField(in session: UnlockSession, timeout: TimeInterval) async throws -> Driver.Field {
        let deadline = driver.monotonicTime() + timeout
        while true {
            try requireLockedSession(session)
            let permission = driver.permissions()
            guard permission.accessibility && permission.postEvents else { throw ScreenUnlockFailure.permissions }
            if let field = driver.focusedPasswordField() { return field }
            guard driver.monotonicTime() < deadline else { throw ScreenUnlockFailure.focus }
            try await driver.pause(min(0.05, deadline - driver.monotonicTime()))
        }
    }

    private func waitForLength(_ lengths: Set<Int>, field: Driver.Field,
                               session: UnlockSession, timeout: TimeInterval) async throws {
        let deadline = driver.monotonicTime() + timeout
        while true {
            try requireField(field, in: session)
            if let length = driver.fieldLength(field), lengths.contains(length) { return }
            guard driver.monotonicTime() < deadline else { throw ScreenUnlockFailure.timeout }
            try await driver.pause(min(0.05, deadline - driver.monotonicTime()))
        }
    }
}
