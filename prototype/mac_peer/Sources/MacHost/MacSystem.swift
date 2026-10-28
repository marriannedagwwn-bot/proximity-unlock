import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import PeerCore
import SystemConfiguration

/// 主程序原有的锁屏、亮屏和空闲检测后端；解锁另走有会话和安全焦点校验的异步流程。
public final class MacSystem: HostSystem {
    private static let inputTypes: [CGEventType] = [
        .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .scrollWheel,
    ]
    private let unlockWorkflow = ScreenUnlockWorkflow(driver: AccessibilityUnlockDriver())

    public init() {}

    public func idleSeconds() -> Double? {
        Self.inputTypes.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()
    }

    public func screenLocked() -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            return (session["CGSSessionScreenIsLocked"] as? Bool) == true
        }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]],
            let me = users.first(where: { ($0["kCGSSessionUserNameKey"] as? String) == NSUserName() })
        else { return false }
        if (me["kCGSSessionOnConsoleKey"] as? Bool) == false { return true }
        return (me["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    public func lockScreen() -> (ok: Bool, note: String) {
        typealias LockFn = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW)
        else { return (false, "找不到 login.framework") }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return (false, "找不到 SACLockScreenImmediate") }
        let rc = unsafeBitCast(sym, to: LockFn.self)()
        return (rc == 0, rc == 0 ? "" : "SACLockScreenImmediate 返回 \(rc)")
    }

    public func displayOff() -> (ok: Bool, note: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        do { try p.run() }
        catch { return (false, "pmset 启动失败：\(error.localizedDescription)") }
        p.waitUntilExit()
        return (p.terminationStatus == 0, p.terminationStatus == 0 ? "" : "pmset 返回 \(p.terminationStatus)")
    }

    public func displayOn() -> (ok: Bool, note: String) {
        var id: IOPMAssertionID = 0
        let rc = IOPMAssertionDeclareUserActivity("手机回来了，点亮屏幕" as CFString, kIOPMUserActiveLocal, &id)
        guard rc == kIOReturnSuccess else { return (false, "IOPMAssertionDeclareUserActivity 返回 \(rc)") }
        let assertion = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { IOPMAssertionRelease(assertion) }
        return (true, "")
    }

    public func unlockScreen(password: String) async -> (ok: Bool, note: String) {
        await unlockWorkflow.unlock(password: password)
    }

    /// 不请求权限、不读取钥匙串、不写 UI；供 --screen-status 使用。
    public static func diagnosticStatus() -> String {
        let driver = AccessibilityUnlockDriver()
        let permission = driver.permissions()
        let state = driver.lockedState().map { $0 ? "已锁屏" : "已解锁" } ?? "未知"
        return "锁屏状态：\(state)；当前用户控制台会话：\(driver.currentSession() == nil ? "未确认" : "已确认")；辅助功能：\(permission.accessibility ? "已授权" : "未授权")；发送系统事件：\(permission.postEvents ? "已授权" : "未授权")"
    }
}

private enum ConsoleState {
    static func ownSessionDictionary() -> [String: Any]? {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], matchesCurrentUser(session) {
            return session
        }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        return users.first(where: matchesCurrentUser)
    }

    static func matchesCurrentUser(_ session: [String: Any]) -> Bool {
        guard let uid = session["kCGSSessionUserIDKey"] as? NSNumber,
              uid.uint32Value == getuid() else { return false }
        if let name = session["kCGSSessionUserNameKey"] as? String, name != NSUserName() { return false }
        return true
    }

    static func identity() -> UnlockSession? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name == NSUserName(), uid == getuid(), uid != 0,
              let session = ownSessionDictionary(),
              (session["kCGSSessionOnConsoleKey"] as? Bool) == true,
              let auditID = (session["kCGSSessionAuditIDKey"] ?? session["kCGSSessionIDKey"]) as? NSNumber
        else { return nil }
        return UnlockSession(username: name, uid: uid, auditID: auditID.uint32Value)
    }

    static func locked() -> Bool? {
        guard identity() != nil, let session = ownSessionDictionary() else { return nil }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        // macOS 在已登录、未锁定的会话里省略 ScreenIsLocked；必须先有明确的登录完成记录才能据此判定。
        if (session["kCGSessionLoginDoneKey"] as? Bool) == true ||
            (session["kCGSSessionLoginDoneKey"] as? Bool) == true { return false }
        return nil
    }
}

private struct PasswordField: Equatable {
    let pid: pid_t
    let element: AXUIElement

    static func == (lhs: PasswordField, rhs: PasswordField) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element)
    }
}

private final class AccessibilityUnlockDriver: ScreenUnlockDriver {
    func permissions() -> UnlockPermissions {
        UnlockPermissions(accessibility: AXIsProcessTrusted(), postEvents: CGPreflightPostEventAccess())
    }
    func currentSession() -> UnlockSession? { ConsoleState.identity() }
    func lockedState() -> Bool? { ConsoleState.locked() }

    func focusedPasswordField() -> PasswordField? {
        guard currentSession() != nil, permissions().accessibility else { return nil }
        let path = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow")
        for application in applications {
            guard application.executableURL?.standardizedFileURL.path == path else { continue }
            let pid = application.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            // 系统调用失败必须尽快返回，避免后台任务长时间等 loginwindow。
            AXUIElementSetMessagingTimeout(app, 0.5)
            guard let focus = attribute(app, kAXFocusedUIElementAttribute),
                  CFGetTypeID(focus) == AXUIElementGetTypeID() else { continue }
            let element = unsafeBitCast(focus, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid,
                  attribute(element, kAXRoleAttribute) as? String == kAXTextFieldRole,
                  attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole else { continue }
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
                  settable.boolValue else { continue }
            return PasswordField(pid: pid, element: element)
        }
        return nil
    }

    func writeValue(_ value: String, to field: PasswordField) throws {
        guard focusedPasswordField() == field, lockedState() == true else { throw ScreenUnlockFailure.focus }
        guard AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString, value as CFString) == .success
        else { throw ScreenUnlockFailure.fieldWrite }
    }

    func fieldLength(_ field: PasswordField) -> Int? {
        guard focusedPasswordField() == field, let value = attribute(field.element, kAXValueAttribute) else { return nil }
        if let string = value as? String { return string.utf16.count }
        if let string = value as? NSAttributedString { return string.length }
        return nil
    }

    func pressKey(_ code: UInt16) async throws {
        try Task.checkCancellation()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { throw ScreenUnlockFailure.fieldWrite }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        defer { up.post(tap: .cghidEventTap) }
        try await pause(0.03)
    }

    func monotonicTime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func pause(_ interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
