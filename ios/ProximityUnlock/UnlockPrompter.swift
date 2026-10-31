import UserNotifications

/// 电脑锁屏后请手机提示解锁（协议 v1，docs/protocol.md「iPhone 端怎么处理提示」）：
/// 心跳里电脑状态是 3、提示编号和上次弹过的不一样 → 发本地通知；电脑状态不再是 3 → 从通知中心撤掉。
///
/// 每台电脑一条通知，identifier 带上电脑的 key（添加时的 identifier），弹过的编号也按电脑分别存：
/// 一台电脑解锁只撤它那条，不影响别的电脑的提示。
/// 弹过的编号和通知还在不在都存在 UserDefaults 里：系统在后台重新拉起 App、电脑端卡死重启后
/// 沿用原来的编号时，都不会重复弹，也不会忘了撤。
/// App 在后台被心跳唤醒的那几秒里就能发通知，不用另外申请后台时间。
final class UnlockPrompter: NSObject, UNUserNotificationCenterDelegate {
    /// 通知的 identifier 是它加上电脑的 key
    private static let requestPrefix = "unlock-prompt-"
    private static let testID = "unlock-test"
    private static let statesKey = "prompt.states"
    private static let unlockCategory = "mac-authenticated-unlock"
    private static let unlockAction = "confirm-mac-unlock"

    private struct PromptState: Codable {
        /// 弹过的最后一个提示编号
        var shownID: Int?
        /// 通知还没撤掉
        var showing = false
        /// optional 兼容旧版本已经保存的状态。
        var allowsUnlock: Bool?
        var automaticUnlock: Bool?
    }

    /// 记日志：事件名、哪台电脑（key）、note
    var log: (String, UUID?, String) -> Void = { _, _, _ in }
    /// 通知权限变了，界面用
    var onAuthorization: (UNAuthorizationStatus) -> Void = { _ in }
    /// 只有用户明确点「解锁」动作才调用；普通点击通知只打开 App。
    var onUnlock: (UUID, UInt16) -> Void = { _, _ in }

    /// 按电脑的 key 分别存
    private var states: [UUID: PromptState] = [:]
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    override init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.statesKey),
           let saved = try? JSONDecoder().decode([String: PromptState].self, from: data) {
            for (key, state) in saved {
                if let id = UUID(uuidString: key) { states[id] = state }
            }
        }
        // 旧版本一次只连一台电脑，通知用固定的 identifier「unlock-prompt」。升级后把旧通知撤掉，
        // 那台电脑还在请提示的话，下一次心跳按新的 identifier 重新弹
        if d.object(forKey: "prompt.shownID") != nil || d.object(forKey: "prompt.showing") != nil {
            if d.bool(forKey: "prompt.showing") {
                let center = UNUserNotificationCenter.current()
                center.removeDeliveredNotifications(withIdentifiers: ["unlock-prompt"])
                center.removePendingNotificationRequests(withIdentifiers: ["unlock-prompt"])
            }
            d.removeObject(forKey: "prompt.shownID")
            d.removeObject(forKey: "prompt.showing")
        }
        super.init()
        let unlock = UNNotificationAction(identifier: Self.unlockAction, title: "解锁",
                                          options: [.foreground, .authenticationRequired])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.unlockCategory, actions: [unlock],
                                   intentIdentifiers: [], options: []),
        ])
        // 要在 App 启动完成前设好，否则点通知打开 App 时收不到回调
        UNUserNotificationCenter.current().delegate = self
    }

    /// App 回到前台时调用：还没问过就申请权限，问过了就刷新一下（用户可能在设置里改了）
    func refreshAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .notDetermined {
                    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                        DispatchQueue.main.async {
                            self.log("notify_auth", nil, granted ? "允许通知" : "不允许通知" + (error.map { "：\($0.localizedDescription)" } ?? ""))
                            self.setAuthorization(granted ? .authorized : .denied)
                        }
                    }
                } else {
                    if settings.authorizationStatus != self.authorization && self.authorization != .notDetermined {
                        self.log("notify_auth", nil, settings.authorizationStatus == .authorized ? "允许通知" : "不允许通知")
                    }
                    self.setAuthorization(settings.authorizationStatus)
                }
            }
        }
    }

    private func setAuthorization(_ status: UNAuthorizationStatus) {
        authorization = status
        onAuthorization(status)
    }

    /// 每台电脑每收到一次心跳调用
    func update(computer: UUID, computerState: UInt8, promptID: UInt16?, computerName: String?,
                allowsUnlock: Bool = false, automaticUnlock: Bool = false) {
        let state = states[computer] ?? PromptState()
        if computerState == ComputerState.promptUnlock, let promptID {
            if Int(promptID) != state.shownID {
                show(computer, promptID, computerName: computerName, allowsUnlock: allowsUnlock, automaticUnlock: automaticUnlock)
            } else if state.showing && ((state.allowsUnlock ?? false) != allowsUnlock
                                       || (state.automaticUnlock ?? false) != automaticUnlock) {
                show(computer, promptID, computerName: computerName, allowsUnlock: allowsUnlock,
                     automaticUnlock: automaticUnlock, silent: true)
            }
        } else if state.showing {
            remove(computer, "电脑状态变成\(ComputerState.label(computerState))")
        }
    }

    /// 忘记了这台电脑：撤掉它的通知，不再记它的编号
    func forget(_ computer: UUID) {
        if states[computer]?.showing == true { remove(computer, "忘记了这台电脑") }
        removeLinkProblem(computer)
        states[computer] = nil
        save()
    }

    private static func requestID(_ computer: UUID) -> String {
        requestPrefix + computer.uuidString
    }

    /// 解锁提示的通知是哪台电脑的；别的通知（比如旧版本的测试通知「unlock-prompt-test」）返回 nil
    private static func computer(of requestID: String) -> UUID? {
        guard requestID.hasPrefix(requestPrefix) else { return nil }
        return UUID(uuidString: String(requestID.dropFirst(requestPrefix.count)))
    }

    private func show(_ computer: UUID, _ id: UInt16, computerName: String?, allowsUnlock: Bool,
                      automaticUnlock: Bool, silent: Bool = false) {
        // 先记下来再异步发：发出去之前又来了心跳也不会重复弹
        states[computer] = PromptState(shownID: Int(id), showing: true, allowsUnlock: allowsUnlock,
                                      automaticUnlock: automaticUnlock)
        save()
        // 同一台电脑用同一个 identifier：新的提示直接替换旧的，每台电脑在通知中心里只留一条
        let requestID = Self.requestID(computer)
        let content = Self.content(computerName)
        content.userInfo = ["promptID": Int(id)]
        if allowsUnlock {
            content.categoryIdentifier = Self.unlockCategory
            content.body = automaticUnlock ? "手机靠近后会自动尝试解锁。也可点「解锁」手动确认。"
                : "是你回来了吗？点「解锁」后在手机上确认。"
        }
        if silent { content.sound = nil }
        content.threadIdentifier = computer.uuidString
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DispatchQueue.main.async { self.log("prompt_error", computer, "id=\(id)：\(error.localizedDescription)") }
                return
            }
            // 记了 prompt_shown 也可能没被看到（横幅只停几秒）。顺带记下系统的通知设置、通知有没有进通知中心，方便查
            Self.diagnose(requestID) { note in
                DispatchQueue.main.async { self.log("prompt_shown", computer, "id=\(id)，\(note)") }
            }
        }
    }

    /// 界面上的「测试通知」：5 秒后弹一条和真的一样的通知，用户趁这几秒锁屏或切到别的 App，看能不能看到
    func sendTest(computerName: String?) {
        let content = Self.content(computerName)
        content.body = "（测试）是你回来了吗？"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(identifier: Self.testID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            DispatchQueue.main.async {
                self.log("prompt_test", nil, error.map { "失败：\($0.localizedDescription)" } ?? "5 秒后弹出")
            }
            guard error == nil else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                Self.diagnose(Self.testID) { note in
                    DispatchQueue.main.async { self.log("prompt_test", nil, "弹出后：\(note)") }
                }
            }
        }
    }

    /// 要用户自己处理的连接问题（比如 iPhone 记着旧的服务、要关开蓝牙）：每台电脑一条，问题过去了撤掉
    func showLinkProblem(_ computer: UUID, computerName: String?, body: String) {
        let content = UNMutableNotificationContent()
        content.title = (computerName ?? "电脑") + " 连不上"
        content.body = body
        content.threadIdentifier = computer.uuidString
        let id = Self.linkProblemPrefix + computer.uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            DispatchQueue.main.async {
                self.log("link_problem_notify", computer, error.map { "失败：\($0.localizedDescription)" } ?? "已弹出")
            }
        }
    }

    func removeLinkProblem(_ computer: UUID) {
        let id = Self.linkProblemPrefix + computer.uuidString
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    private static let linkProblemPrefix = "link-problem-"

    private static func content(_ computerName: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let name = computerName ?? "电脑"
        // 英文电脑名后面空一格：「DESKTOP-ABC123 已锁屏」「模拟电脑已锁屏」
        content.title = name + (name.last?.isASCII == true ? " " : "") + "已锁屏"
        content.body = "是你回来了吗？"
        content.sound = .default
        return content
    }

    /// 通知有没有进通知中心、通知中心里一共有哪几台电脑的提示，加上系统的通知设置
    private static func diagnose(_ identifier: String, _ done: @escaping (String) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            center.getDeliveredNotifications { delivered in
                let inCenter = delivered.contains { $0.request.identifier == identifier }
                done((inCenter ? "已进通知中心" : "通知中心里没有") + "（\(prompts(delivered))）；" + describe(s))
            }
        }
    }

    /// 通知中心里现在是哪几台电脑的解锁提示，用标题区分
    private static func prompts(_ delivered: [UNNotification]) -> String {
        let titles = delivered.filter { computer(of: $0.request.identifier) != nil }.map(\.request.content.title)
        return titles.isEmpty ? "没有解锁提示" : "解锁提示 \(titles.count) 条：" + titles.joined(separator: "、")
    }

    private static func describe(_ s: UNNotificationSettings) -> String {
        func on(_ x: UNNotificationSetting) -> String {
            switch x {
            case .enabled: "开"
            case .disabled: "关"
            default: "-"
            }
        }
        let auth = [UNAuthorizationStatus.authorized: "允许", .denied: "不允许", .notDetermined: "没问过",
                    .provisional: "临时", .ephemeral: "临时"][s.authorizationStatus] ?? "?"
        let style = [UNAlertStyle.none: "无", .banner: "横幅", .alert: "提醒"][s.alertStyle] ?? "?"
        return "权限\(auth) 样式\(style) 提醒\(on(s.alertSetting)) 锁屏\(on(s.lockScreenSetting)) "
            + "通知中心\(on(s.notificationCenterSetting)) 声音\(on(s.soundSetting)) 定时摘要\(on(s.scheduledDeliverySetting))"
    }

    private func remove(_ computer: UUID, _ reason: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestID(computer)])
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID(computer)])
        states[computer, default: PromptState()].showing = false
        save()
        let note = "id=\(states[computer]?.shownID.map(String.init) ?? "?")，\(reason)"
        // 撤是异步的，稍等一下再看通知中心里还剩哪几台电脑的提示，确认只撤了这一台的
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            center.getDeliveredNotifications { delivered in
                DispatchQueue.main.async { self.log("prompt_removed", computer, "\(note)；撤掉后\(Self.prompts(delivered))") }
            }
        }
    }

    private func save() {
        let saved = Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.statesKey)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时系统默认不显示通知，这里让它照样弹
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// 普通点击仍只打开 App；已登记电脑的「解锁」动作才进入签名流程（系统先要求手机解锁，见 authenticationRequired）。
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let computer = Self.computer(of: response.notification.request.identifier) {
            let requestedID = (response.notification.request.content.userInfo["promptID"] as? NSNumber)?.uint16Value
            DispatchQueue.main.async {
                self.log("prompt_tapped", computer, "id=\(self.states[computer]?.shownID.map(String.init) ?? "?")")
                if response.actionIdentifier == Self.unlockAction, let requestedID {
                    self.onUnlock(computer, requestedID)
                }
            }
        }
        completionHandler()
    }
}
