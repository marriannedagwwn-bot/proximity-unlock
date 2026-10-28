import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import notify
import OpenDirectory
import PeerCore
import Security

public struct StoredUnlockCredential: Codable {
    public let username: String
    public let password: String
    public let key: UnlockKey

    public init(username: String, password: String, key: UnlockKey) {
        self.username = username
        self.password = password
        self.key = key
    }
}

public enum MacUnlockStoreError: LocalizedError {
    case keychain(OSStatus), invalidCredential, passwordVerification, randomFailure, mainThreadRequired

    public var errorDescription: String? {
        switch self {
        case .keychain(let code): return "本机解锁登记的钥匙串操作失败（\(code)）"
        case .invalidCredential: return "本机解锁登记无效或不属于当前用户"
        case .passwordVerification: return "未能确认当前用户的登录密码；没有保存登记"
        case .randomFailure: return "无法生成安全的登记密钥"
        case .mainThreadRequired: return "本机解锁设置需要从应用主线程打开"
        }
    }
}

public enum MacUnlockStore {
    private static let service = "com.proximity-unlock.mac.credentials.v1"
    /// 后台电脑端验过手机的登记确认后发这个 Darwin 通知，登记窗口进程收到就关（docs/protocol.md「登记确认」）
    public static let enrollAckNotification = "com.proximity-unlock.mac.enroll-ack"

    public static func postEnrollAck() {
        notify_post(enrollAckNotification)
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: NSUserName(),
         kSecAttrSynchronizable as String: false]
    }

    /// 启动读取绝不弹交互认证框；不可读时由主程序保持解锁关闭。
    public static func load() throws -> StoredUnlockCredential? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MacUnlockStoreError.keychain(status) }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(StoredUnlockCredential.self, from: data) else {
            throw MacUnlockStoreError.invalidCredential
        }
        try validate(credential)
        return credential
    }

    public static func save(_ credential: StoredUnlockCredential) throws {
        try validate(credential)
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw MacUnlockStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw MacUnlockStoreError.keychain(status)
        }
    }

    public static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MacUnlockStoreError.keychain(status) }
    }

    /// 仅 --setup-unlock 的本机 UI 调用。密码和登记密钥均不输出到终端、日志、文件或剪贴板。
    public static func configureInteractively() throws -> Bool {
        guard Thread.isMainThread else { throw MacUnlockStoreError.mainThreadRequired }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        do {
            return try presentConfiguration()
        } catch {
            showSetupError(error)
            throw error
        }
    }

    /// 手机在 App 里点了「扫码登记」，后台电脑端起的这个进程（--setup-unlock --phone-request）。
    /// 先问一句再显示：附近任何设备都能发这个请求，二维码就是能解锁这台 Mac 的密钥（docs/protocol.md「手机请求显示登记码」）。
    /// 已登记就显示现有登记码（不换密钥、不用输密码），没登记走本机登记
    public static func configureForPhoneRequest() throws -> Bool {
        guard Thread.isMainThread else { throw MacUnlockStoreError.mainThreadRequired }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        do {
            let enrolled: StoredUnlockCredential? = {
                guard let stored = (try? load()) ?? nil, (try? validate(stored)) != nil else { return nil }
                return stored
            }()
            let ask = NSAlert()
            if enrolled != nil {
                ask.messageText = "iPhone 请求显示登记二维码"
                ask.informativeText = "有 iPhone 通过蓝牙请求登记靠近解锁这台 Mac。是你自己在手机上点的「扫码登记」，就点「显示二维码」，用那部手机扫；不是你点的就选「不用」。\n二维码就是解锁这台 Mac 的密钥，别让别人拍到。「重新登记」会换新密钥，旧的手机登记随之失效。"
                ask.addButton(withTitle: "显示二维码")
                ask.addButton(withTitle: "不用")
                ask.addButton(withTitle: "重新登记…")
            } else {
                ask.messageText = "iPhone 请求登记靠近解锁"
                ask.informativeText = "有 iPhone 通过蓝牙请求登记靠近解锁这台 Mac。是你自己在手机上点的「扫码登记」，就点「登记」：输入这台 Mac 的登录密码后会显示二维码，用那部手机扫。不是你点的就选「不用」。"
                ask.addButton(withTitle: "登记…")
                ask.addButton(withTitle: "不用")
            }
            ask.buttons[1].keyEquivalent = "\u{1b}"
            switch ask.runInFront() {
            case .alertFirstButtonReturn:
                if let enrolled {
                    try showEnrollmentCode(enrolled.key, newEnrollment: false)
                    return true
                }
                return try presentConfiguration()
            case .alertThirdButtonReturn:
                return try presentConfiguration()
            default:
                return false
            }
        } catch {
            showSetupError(error)
            throw error
        }
    }

    /// open 启动时 stderr 不可见；只显示预先定义的原因，不能把系统错误里的用户输入带进提示。
    private static func showSetupError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "本机解锁登记未完成"
        let reason: String
        switch error {
        case MacUnlockStoreError.passwordVerification:
            reason = "未能确认当前用户的 Mac 登录密码，请检查后重新登记。"
        case MacUnlockStoreError.keychain(let status):
            reason = "钥匙串未允许完成登记（错误码 \(status)）。请解锁本机钥匙串后重新登记。"
        case MacUnlockStoreError.invalidCredential:
            reason = "输入或登记资料无效，请为当前 Mac 用户重新登记。"
        case MacUnlockStoreError.randomFailure:
            reason = "系统未能生成安全的登记密钥，请稍后重试。"
        default:
            reason = "本机登记无法完成，请重新打开解锁设置。"
        }
        alert.informativeText = reason + "\n请使用最终安装的同一 MacPeer.app 完成授权和登记。"
        alert.addButton(withTitle: "知道了")
        alert.runInFront()
    }

    private static func presentConfiguration() throws -> Bool {
        if !AXIsProcessTrusted() || !CGPreflightPostEventAccess() {
            let alert = NSAlert()
            alert.messageText = "先允许 MacPeer 控制登录界面"
            alert.informativeText = "需要在系统设置中允许 MacPeer 的辅助功能和发送系统事件权限。请使用最终安装的同一 MacPeer.app 完成授权和登记；完成授权后重新打开本机解锁设置。此时不会保存密码或登记密钥。"
            alert.addButton(withTitle: "打开授权")
            alert.addButton(withTitle: "取消")
            guard alert.runInFront() == .alertFirstButtonReturn else { return false }
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            _ = CGRequestPostEventAccess()
            return false
        }

        let alert = NSAlert()
        alert.messageText = "启用手机靠近自动解锁此 Mac"
        alert.informativeText = "请输入当前用户 \(NSUserName()) 的 Mac 登录密码。密码只保存在此 Mac 的钥匙串；手机只登记随机密钥。登记后，这台手机靠近并满足电脑端判断条件时会自动解锁 Mac，不再逐次确认。重新登记会使旧的手机登记失效。"
        alert.addButton(withTitle: "保存并生成手机登记码")
        alert.addButton(withTitle: "取消")
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        input.placeholderString = "Mac 登录密码"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        defer { input.stringValue = "" }
        guard alert.runInFront() == .alertFirstButtonReturn else { return false }
        let password = input.stringValue
        guard !password.isEmpty, !password.contains("\0") else { throw MacUnlockStoreError.invalidCredential }
        do {
            let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
        } catch {
            throw MacUnlockStoreError.passwordVerification
        }

        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw MacUnlockStoreError.randomFailure }
        let key = UnlockKey(id: UInt32.random(in: 1...UInt32.max), secret: bytes)
        try save(StoredUnlockCredential(username: NSUserName(), password: password, key: key))
        input.stringValue = ""
        try showEnrollmentCode(key, newEnrollment: true)
        return true
    }

    /// 显示登记码（二维码 + JSON）。手机扫码保存后发来的登记确认由后台电脑端验过、用 Darwin 通知转过来，
    /// 收到就清掉二维码、显示一句再自己关，和点「完成」一样往下走；新登记接着重启后台电脑端，让新密钥生效
    private static func showEnrollmentCode(_ key: UnlockKey, newEnrollment: Bool) throws {
        let registration: [String: Any] = ["version": 1, "keyID": key.id, "secret": key.secret.base64EncodedString()]
        let data = try JSONSerialization.data(withJSONObject: registration, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        let finished = NSAlert()
        finished.messageText = "在 iPhone 中登记这台 Mac"
        finished.informativeText = newEnrollment
            ? "在 iPhone App 的这台电脑详情中点「扫码登记」扫下面的二维码，或者手动复制下方完整登记码。它不含 Mac 密码，但持有它的手机靠近时可以自动请求解锁，请只登记到自己的手机，别让别人拍到二维码。登记码不会自动复制到剪贴板。\n手机保存登记码后点“完成”，程序将尝试重启已安装的电脑端，使本次登记立即生效。请使用最终安装的同一 MacPeer.app 完成授权和登记；更换程序签名后可能需要重新授权和登记。"
            : "这是这台 Mac 现在的登记码，没有换新密钥。在 iPhone App 这台电脑的详情里点「扫码登记」扫下面的二维码，手机保存后这个窗口会自己关；也可以手动复制下方登记码。它不含 Mac 密码，但持有它的手机靠近时可以自动请求解锁，请只登记到自己的手机，别让别人拍到二维码。"
        finished.addButton(withTitle: "完成")
        let qrSide: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: qrSide + 12 + 100))
        let qrView = NSImageView(frame: NSRect(x: (430 - qrSide) / 2, y: 112, width: qrSide, height: qrSide))
        qrView.imageScaling = .scaleProportionallyUpOrDown
        if let qr = EnrollmentQRCode.cgImage(for: text) {
            qrView.image = NSImage(cgImage: qr, size: NSSize(width: qrSide, height: qrSide))
        }
        container.addSubview(qrView)
        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 0, y: 112 + qrSide / 2 - 12, width: 430, height: 24)
        status.alignment = .center
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.isHidden = true
        container.addSubview(status)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 100))
        let view = NSTextView(frame: scroll.bounds)
        view.string = text
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        container.addSubview(scroll)
        finished.accessoryView = container

        // 登记确认：每 0.25 秒查一次 Darwin 通知（模态窗口里也照跑）。刚注册时第一次查总是 1，先消掉
        var token: Int32 = 0
        let watching = notify_register_check(enrollAckNotification, &token) == 0
        var posted: Int32 = 0
        if watching { notify_check(token, &posted) }
        var acknowledged = false
        let poll = Timer(timeInterval: 0.25, repeats: true) { _ in
            guard watching, !acknowledged else { return }
            notify_check(token, &posted)
            guard posted != 0 else { return }
            acknowledged = true
            qrView.image = nil
            view.string = ""
            scroll.isHidden = true
            status.stringValue = "已收到 iPhone 确认，即将关闭"
            status.isHidden = false
            let close = Timer(timeInterval: 1.5, repeats: false) { _ in
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
            RunLoop.main.add(close, forMode: .common)
        }
        RunLoop.main.add(poll, forMode: .common)
        finished.runInFront()
        poll.invalidate()
        if watching { notify_cancel(token) }
        view.string = ""
        qrView.image = nil
        if newEnrollment {
            showHostRestartResult(restartInstalledHost())
        }
    }

    private enum HostRestartResult { case restarted, differentApplication, failed }

    /// 只重启当前用户已安装、且与本进程可执行路径完全一致的那一个服务。不改配置、不重建或重签名。
    private static func restartInstalledHost() -> HostRestartResult {
        let label = "io.github.marriannedagwwn.MacPeer"
        let plist = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard getuid() != 0,
              let executable = Bundle.main.executableURL?.standardizedFileURL,
              let data = try? Data(contentsOf: plist),
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              dictionary["Label"] as? String == label,
              let arguments = dictionary["ProgramArguments"] as? [String],
              let installed = arguments.first, installed.hasPrefix("/"),
              URL(fileURLWithPath: installed).standardizedFileURL.path == executable.path,
              !arguments.contains(where: { ["--setup-unlock", "--forget-unlock", "--screen-status"].contains($0) })
        else { return .differentApplication }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { return .failed }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? .restarted : .failed
    }

    private static func showHostRestartResult(_ result: HostRestartResult) {
        let alert = NSAlert()
        switch result {
        case .restarted:
            alert.messageText = "已重启已安装的 Mac 电脑端"
            alert.informativeText = "本机登记已保存，后台电脑端已重新启动并将读取本次登记。请在 iPhone 中保存登记码后，按实际离开、回来的场景验证自动解锁。"
        case .differentApplication:
            alert.messageText = "登记已保存，请使用已安装的同一 MacPeer.app"
            alert.informativeText = "当前程序与登录自启配置中的可执行路径不一致，或尚未安装登录自启，因此没有自动重启。请打开最终安装的 MacPeer.app，重新完成授权和登记。需要手动重启时，在项目的 prototype/mac_peer 目录依次运行 ./autostart.sh stop 和 ./autostart.sh start。"
        case .failed:
            alert.messageText = "登记已保存，电脑端需要手动重启"
            alert.informativeText = "系统没有完成后台电脑端的重启。在项目的 prototype/mac_peer 目录依次运行 ./autostart.sh stop 和 ./autostart.sh start，使本次登记生效。请使用同一 MacPeer.app，不要在登记后重新编译或更换签名。"
        }
        alert.addButton(withTitle: "知道了")
        alert.runInFront()
    }

    static func validate(_ credential: StoredUnlockCredential) throws {
        guard credential.username == NSUserName(), !credential.password.isEmpty,
              !credential.password.contains("\0"), credential.password.utf8.count <= 16_384,
              credential.key.secret.count == 32, credential.key.secret.contains(where: { $0 != 0 }) else {
            throw MacUnlockStoreError.invalidCredential
        }
    }
}

extension NSAlert {
    /// 手机请求起的登记窗口进程不是用户点开的，macOS 14 起系统不让它抢到最前面；
    /// 系统对话框默认在程序不在最前面时自己藏起来，不处理的话要先点一下 MacPeer 才看得到。
    /// 改成不藏、放到普通窗口上面一层、在所有桌面都显示，并让程序坞图标跳动。点一下窗口就能输入
    func runInFront() -> NSApplication.ModalResponse {
        (window as? NSPanel)?.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.requestUserAttention(.criticalRequest)
        return runModal()
    }
}
