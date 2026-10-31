import CoreBluetooth
import Observation
import UIKit

private struct PendingRead {
    let seq: UInt32
    let at: Date
    let note: String
    /// 不是心跳触发的，是被 iBeacon 区域事件叫醒时主动读的（见「休眠」）
    var wake = false
}

struct RSSISample {
    let time: Date
    let rssi: Int
}

/// 发现服务进行到哪一步（见 ComputerLink「发现服务」）
private enum DiscoveryStep {
    case idle
    case services
    case characteristics
}

private enum UnlockStep {
    case readingChallenge, writingCommand
}

private struct PendingUnlock {
    let token: UUID
    let promptID: UInt16
    var step: UnlockStep
    let automatic: Bool
    /// 这是断线后补发的那一次：它再断也不再补
    var retry = false
    /// 签名请求交给系统发出的时间
    var sentAt: Date?
}

/// 签名请求发出后、等电脑回复时连接断了，结果未确认：重新连上后可以补发一次（见「解锁请求补发」）
private struct UnlockRetry {
    let promptID: UInt16
    /// 发出时电脑的认证会话（INFO 的 reportNonce）；变了说明电脑端重启过，不补
    let session: Data
    let automatic: Bool
    let sentAt: Date
}

/// 首页锁按钮（手动解锁、锁屏）的结果，卡片上显示几秒就清掉
struct ActionFeedback: Equatable {
    let text: String
    let failed: Bool
    let at: Date
}

private struct PendingReportWrite {
    let characteristic: CBCharacteristic
    /// nil 表示旧的未认证报告；不能用这种成功回复建立认证状态。
    let authenticatedSession: UUID?
    let at: Date
}

enum LinkPhase {
    case bluetoothUnavailable
    /// 系统找不到记住的那台（取不回外设对象），只能等搜索搜到它
    case searching
    /// 已发起连接。断开后也是这个状态：连接请求挂着不会超时，回到范围内系统自动连上
    case connecting
    case connected
}

/// 记住的一台电脑，存在 UserDefaults 里
struct SavedComputer: Codable {
    /// 添加时的 identifier，之后不变：界面列表、通知、弹过的提示编号都按它区分
    let key: UUID
    /// 现在的 identifier。电脑换了地址、App 改连新地址（adopt）后更新
    var id: UUID
    var name: String?
    /// INFO 里报的名字。电脑换了地址（identifier 变了）时靠它认出同一台电脑
    var infoName: String?
}

/// 一台电脑的连接（docs/protocol.md「iPhone 端流程」）：
/// 连接电脑 → 订阅 HEARTBEAT → 每收到一次心跳读一次 RSSI → 写 REPORT；断开后立即挂起重连。
///
/// 每台电脑一份，心跳、RSSI、REPORT、看门狗、等服务回来、手机判断都各管各的，一台卡住不影响别的。
/// central、搜索、连上读 INFO 核对换了地址的电脑、日志文件由 LinkManager 统一管。
@Observable
final class ComputerLink: NSObject, Identifiable {
    let key: UUID
    var id: UUID { key }
    let isSimulated: Bool

    private(set) var savedID: UUID
    private(set) var name: String?
    private(set) var infoName: String?
    private(set) var platform: String?
    private(set) var protoWarning: String?
    private(set) var supportsUnlock = false
    /// INFO 的 manual ≥ 1：锁着、没在请提示时也能手动解锁，也能让电脑锁屏（docs/protocol.md「手动锁屏、解锁」）
    private(set) var supportsManual = false
    private(set) var authenticatedReportsReady = false
    private(set) var hasUnlockEnrollment = false
    private(set) var automaticUnlockEnabled = false
    private(set) var unlockBusy = false
    private(set) var unlockStatus: String?
    /// 正在等电脑回锁屏命令的结果
    private(set) var lockBusy = false
    /// 首页锁按钮的结果，几秒后清掉
    private(set) var actionFeedback: ActionFeedback?
    /// 测试用：下一次签好名的解锁请求不发出去，直接断开连接，模拟「发出后连接断了」，看补发对不对。只生效一次
    private(set) var simulateUnlockDrop = false
    private var unlockTransportReady = false
    private(set) var phase: LinkPhase = .connecting {
        // 有电脑没连上时 LinkManager 要按服务 UUID 搜索，找换了地址的它
        didSet { if phase != oldValue { owner.updateScan() } }
    }
    private(set) var subscribed = false
    private(set) var disconnectedAt: Date?
    /// 要用户自己处理的连接问题（比如配对被删了），界面上显示，配合「重新连接」按钮
    private(set) var linkProblem: String?
    /// 上一次连接时加密超时的时间，连上或用户点「重新连接」时清掉。60 秒内连着两次才算配对问题（见 didFailToConnect）
    @ObservationIgnored private var encryptTimeoutAt: Date?
    private static let encryptRetryWindow: TimeInterval = 60
    /// 连着但电脑上没有协议服务（电脑端程序停了）的开始时间
    private(set) var serviceMissingSince: Date?

    private(set) var lastRSSI: Int?
    private(set) var lastHeartbeatAt: Date?
    /// 心跳里的电脑状态（ComputerState）和提示编号，v0 电脑端没有提示编号
    private(set) var computerState: UInt8?
    private(set) var promptID: UInt16?
    /// 最近一次心跳宣布的「下一次最晚几秒后到」（v1.2），v1 电脑端没有。断开重连也留着：电脑那边说话算话，
    /// 重新订阅以后下一次心跳也可能要等这么久
    private(set) var announcedInterval: Int?
    private(set) var phoneState: PhoneState = .undetermined
    /// 最近 3 分钟的 RSSI，画图用
    private(set) var samples: [RSSISample] = []

    private unowned let owner: LinkManager
    @ObservationIgnored private(set) var peripheral: CBPeripheral?
    @ObservationIgnored private var heartbeatChar: CBCharacteristic?
    @ObservationIgnored private var reportChar: CBCharacteristic?
    @ObservationIgnored private var infoChar: CBCharacteristic?
    @ObservationIgnored private var unlockChallengeChar: CBCharacteristic?
    @ObservationIgnored private var unlockCommandChar: CBCharacteristic?
    @ObservationIgnored private var enrollAckChar: CBCharacteristic?
    @ObservationIgnored private var enrollRequestChar: CBCharacteristic?
    @ObservationIgnored private var lockCommandChar: CBCharacteristic?
    /// 这一次锁屏命令，回复或超时以后清掉
    @ObservationIgnored private var lockToken: UUID?
    /// 电脑对「请电脑显示登记码」的回复，扫码页上显示；这次扫码没发请求（电脑端太旧、没连上）是 nil
    private(set) var enrollRequestStatus: String?
    /// 刚保存、还没发登记确认的登记和保存时间（见「登记确认」）
    @ObservationIgnored private var enrollAckPending: (enrollment: UnlockEnrollment, savedAt: Date)?
    /// 保留已完成发现轮次的特征存在性，resetLink 清当前句柄时不清这个快照。
    @ObservationIgnored private var lastDiscoveredUnlockTransport: Bool?
    @ObservationIgnored private var lastDiscoveredUnlockService: CBService?
    @ObservationIgnored private var unlockReportSessionNonce: Data?
    @ObservationIgnored private var unlockEnrollmentCache: UnlockEnrollment?
    @ObservationIgnored private var reportPresenceSession = UUID()
    @ObservationIgnored private var confirmedAuthenticatedReportAt: Date?
    @ObservationIgnored private var pendingReportWrite: PendingReportWrite?
    @ObservationIgnored private var pendingUnlock: PendingUnlock?
    @ObservationIgnored private var lastAutomaticUnlockAttempt: AutomaticUnlockAttempt?
    /// 等着补发的那次请求。只放在内存里：App 中途被结束重新启动就不补（宁可少补）
    @ObservationIgnored private var unlockRetry: UnlockRetry?
    /// 解锁挑战和电脑完成认证需跨几个蓝牙回调，独立于「等服务」的后台时间。
    @ObservationIgnored private var unlockBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var unlockBackgroundToken: UUID?
    // 超时后不复用尚未回调的 GATT 请求；它的结果仍可能迟到。
    private var unlockReadOutstanding = false
    private var unlockWriteOutstanding = false
    /// 同时只发现一轮服务，发现完才订阅、读 INFO
    @ObservationIgnored private var discovery: DiscoveryStep = .idle
    /// 发现的过程中电脑的服务又变了：这一轮的结果作废，回来后再发现一次
    @ObservationIgnored private var rediscover = false
    /// 已经排了一次「3 秒后重新找服务」，不再排第二次
    @ObservationIgnored private var serviceRetryScheduled = false
    /// 这条连接上读到过 INFO：服务变了要重新发现、重新订阅，但不用再读。电脑端程序重启过（服务没了又回来）就清掉
    @ObservationIgnored private var infoRead = false
    /// 正在读 INFO 的特征值：同一个特征值还没读完就不再读
    @ObservationIgnored private var infoReading: CBCharacteristic?
    /// 等电脑端服务回来时申请的后台时间，免得 App 在后台被挂起、轮询停掉
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 因为等不到服务而主动断开的时间
    @ObservationIgnored private var droppedForServiceAt: Date?
    /// 主动断开后系统马上又连回来了：链路其实没断（实测配对后就是这样），再断也没用
    @ObservationIgnored private var dropDoesNothing = false
    /// 心跳看门狗：每次重新计时加一，过期的检查就作废
    @ObservationIgnored private var watchdogGeneration = 0
    /// 看门狗连续触发了几次，用来把等待时间翻倍；收到心跳就清零
    @ObservationIgnored private var watchdogResets = 0
    /// 协议服务不止一个时这次用第几个（见下面「旧服务」）
    @ObservationIgnored private var serviceIndex = 0
    /// 上一轮发现到几个协议服务
    @ObservationIgnored private var serviceCount = 0
    /// 收到心跳以前因为旧服务换过几次，换遍了就不再马上换，等看门狗
    @ObservationIgnored private var serviceSwitches = 0
    /// 连续几轮碰到旧服务的错误（收到心跳就清零）；这一轮算过了没有
    @ObservationIgnored private var staleRounds = 0
    @ObservationIgnored private var staleThisRound = false
    /// 弹过「关开蓝牙」的通知，收到心跳以前不再弹
    @ObservationIgnored private var staleNotified = false
    /// App 自己断开连接的原因，didDisconnect 记日志用
    @ObservationIgnored private var selfDropReason: String?
    /// 正在读 RSSI 的那次心跳。iOS 读一次 RSSI 要约 1.05 秒（真机实测），
    /// 比心跳间隔（约 1.01 秒）还长，所以同时只读一次，不排队，否则延迟会越积越大。
    /// readRSSI 是按外设分别的，每台电脑各读各的
    @ObservationIgnored private var reading: PendingRead?
    /// 读的过程中来的心跳只留最新的一次，读完接着读它
    @ObservationIgnored private var waiting: PendingRead?
    @ObservationIgnored private var lastSeq: UInt32?
    @ObservationIgnored private var judge: ProximityJudge
    @ObservationIgnored private var simTimer: Timer?
    @ObservationIgnored private var simSeq: UInt32 = 0
    @ObservationIgnored private var simLevel = -58.0
    /// 模拟器里点了锁按钮：这台假电脑保持这个状态到某个时间，不按一轮一轮走
    @ObservationIgnored private var simHold: (state: UInt8, until: Date)?

    init(owner: LinkManager, saved: SavedComputer, settings: JudgeSettings, simulated: Bool = false) {
        self.owner = owner
        key = saved.key
        savedID = saved.id
        name = saved.name
        infoName = saved.infoName
        isSimulated = simulated
        judge = ProximityJudge(settings: settings)
        super.init()
        hasUnlockEnrollment = UnlockKeychain.contains(key)
        automaticUnlockEnabled = UnlockPreferences.automaticEnabled(key, enrolled: hasUnlockEnrollment)
        lastAutomaticUnlockAttempt = UnlockPreferences.lastAutomaticAttempt(key)
    }

    var saved: SavedComputer {
        SavedComputer(key: key, id: savedID, name: name, infoName: infoName)
    }

    /// 日志的 device 列：电脑名（identifier 前 8 位）
    var deviceLabel: String {
        "\(name ?? "未知")（\((peripheral?.identifier ?? savedID).uuidString.prefix(8))）"
    }

    /// 没连上时 LinkManager 也在按服务 UUID 找换了地址的它（读过 INFO 才能核对名字）
    var searchingMoved: Bool {
        phase != .connected && infoName != nil && owner.scanning
    }

    /// 电脑在休眠：心跳宣布的间隔 ≥ 10 秒（docs/protocol.md「心跳快慢和休眠」，休眠是 30 秒一次）
    var dormant: Bool {
        (announcedInterval ?? 1) >= Self.dormantInterval
    }

    /// 连接、登记、本连接的认证报告都就绪，可以发签名请求（不看电脑状态）
    private var unlockReady: Bool {
        phase == .connected && subscribed && supportsUnlock && hasUnlockEnrollment && infoRead && authenticatedReportsReady
            && unlockTransportReady
            && !unlockBusy && !unlockReadOutstanding && !unlockWriteOutstanding && !isSimulated
    }

    /// 电脑在请提示，可以按这次提示解锁（自动解锁、通知上的「解锁」、补发）
    var canRequestUnlock: Bool {
        unlockReady && computerState == ComputerState.promptUnlock && promptID != nil
    }

    /// 首页锁按钮、详情页「现在解锁」：电脑在请提示就按提示解；只是锁着时手动解（电脑端要支持，INFO 的 manual）
    var canManualUnlock: Bool {
        if isSimulated {
            return !unlockBusy && !lockBusy
                && (computerState == ComputerState.locked || computerState == ComputerState.promptUnlock)
        }
        return canRequestUnlock || (unlockReady && supportsManual && computerState == ComputerState.locked)
    }

    /// 首页锁按钮：电脑没锁屏时让它锁屏。和认证报告一样用登记密钥签名，带最近一次心跳的 seq
    var canRemoteLock: Bool {
        if isSimulated { return !unlockBusy && !lockBusy && computerState == ComputerState.unlocked }
        return phase == .connected && subscribed && supportsManual && lockCommandChar != nil && infoRead
            && authenticatedReportsReady && unlockEnrollmentCache != nil && lastSeq != nil
            && computerState == ComputerState.unlocked && !lockBusy && !unlockBusy
    }

    /// 这次解锁的目标还在：按提示解锁要电脑还在请同一次提示；手动解锁（编号 0）要电脑还锁着、没在请提示
    private static func unlockTarget(_ id: UInt16, matches state: UInt8?, _ prompt: UInt16?) -> Bool {
        id == UnlockProtocol.manualPromptID ? state == ComputerState.locked
            : state == ComputerState.promptUnlock && prompt == id
    }

    /// 登记保存到本机钥匙串并默认开启自动解锁；下一次有效的靠近提示可触发一次尝试。
    func enrollUnlock(_ text: String) throws {
        let enrollment = try UnlockEnrollment.parse(text)
        try UnlockKeychain.save(enrollment, for: key)
        cancelUnlock("登记已更新，旧的解锁请求已停止。")
        skipUnlockRetry("登记已更新，不补发")
        hasUnlockEnrollment = true
        unlockEnrollmentCache = enrollment
        updateAuthenticatedReportsReady()
        automaticUnlockEnabled = true
        UnlockPreferences.setAutomatic(true, for: key)
        unlockStatus = "已登记，手机靠近时会自动尝试解锁这台电脑。"
        refreshUnlockPrompt()
        enrollAckPending = (enrollment, Date())
        sendEnrollAckIfReady()
    }

    func removeUnlockEnrollment() throws {
        try UnlockKeychain.delete(key)
        cancelUnlock("解锁登记已删除。")
        skipUnlockRetry("解锁登记已删除，不补发")
        hasUnlockEnrollment = false
        unlockEnrollmentCache = nil
        enrollAckPending = nil
        updateAuthenticatedReportsReady()
        automaticUnlockEnabled = false
        UnlockPreferences.setAutomatic(false, for: key)
        unlockStatus = "已删除解锁登记。"
        refreshUnlockPrompt()
    }

    func setAutomaticUnlock(_ enabled: Bool) {
        automaticUnlockEnabled = enabled && hasUnlockEnrollment
        UnlockPreferences.setAutomatic(automaticUnlockEnabled, for: key)
        if !automaticUnlockEnabled, pendingUnlock?.automatic == true {
            cancelUnlock("已关闭自动解锁，本次尚未完成的请求已停止。")
        }
        if !automaticUnlockEnabled, unlockRetry?.automatic == true { skipUnlockRetry("已关闭自动解锁，不补发") }
        refreshUnlockPrompt()
    }

    /// INFO/登记/前台或首次解锁时更新一次缓存，不在每秒报告路径反复访问钥匙串。
    func refreshUnlockAuthorization() {
        guard supportsUnlock, unlockReportSessionNonce != nil else { return }
        if unlockEnrollmentCache == nil {
            do {
                unlockEnrollmentCache = try UnlockKeychain.load(key)
                hasUnlockEnrollment = unlockEnrollmentCache != nil
            } catch {
                unlockStatus = error.localizedDescription
            }
        }
        updateAuthenticatedReportsReady()
        refreshUnlockPrompt()
    }

    private func updateAuthenticatedReportsReady() {
        authenticatedReportsReady = supportsUnlock && unlockReportSessionNonce?.count == 16
            && unlockEnrollmentCache != nil && canWriteAuthenticatedReports && hasFreshAuthenticatedReport
    }

    private var canWriteAuthenticatedReports: Bool {
        guard let p = peripheral, let c = reportChar else { return false }
        // 每条认证报告都等写回复，成功后才知道电脑接受了这条 RSSI。
        return c.properties.contains(.write) && p.maximumWriteValueLength(for: .withResponse) >= 35
    }

    private var hasFreshAuthenticatedReport: Bool {
        guard let at = confirmedAuthenticatedReportAt else { return false }
        return Date().timeIntervalSince(at) <= max(10, Double(announcedInterval ?? 1) + 5)
    }

    private func resetAuthenticatedReportConfirmation() {
        reportPresenceSession = UUID()
        confirmedAuthenticatedReportAt = nil
        authenticatedReportsReady = false
    }

    private func authenticatedReportFailed(_ message: String, detail: String) {
        authenticatedReportsReady = false
        if unlockStatus != message { record("report_auth_error", note: detail) }
        unlockStatus = message
    }

    private func invalidateUnlockReportSession() {
        unlockReportSessionNonce = nil
        unlockEnrollmentCache = nil
        resetAuthenticatedReportConfirmation()
        cancelUnlock("电脑的认证会话已变化，本次请求已停止。")
    }

    // MARK: - 解锁请求补发
    //
    // 真机上碰到过：手机发出签名请求 1.2 秒后链路超时，没收到电脑的回复，记成「结果未确认、没有自动重试」，
    // 其实 Mac 已经解锁了。手机回到电脑附近的头几分钟，和 Mac 的连接常常每十几秒超时一次，请求要是没送到，就只能手动解锁。
    // 所以：请求已经发出、在等回复时连接断了（链路断开或电脑端服务变了），重新连上后电脑还在请同一次提示、
    // 认证会话没变（电脑端没重启）、离第一次发出不到 120 秒（电脑那边这次提示的有效期），就重新读挑战、
    // 用新的一次性签名补发一次。每次提示最多补一次；自动、手动（用户点了解锁的）都补。
    // 不会重复解锁：电脑每个随机数只核对一次，正在执行解锁时不给新挑战，已经解锁就不再是状态 3。
    // 电脑明确回了失败、连着但 30 秒没回复、后台时间用完、用户改了登记或关了自动解锁，都不补。

    private static let unlockRetryWindow = 120.0

    private func attemptUnlockRetry() {
        guard let retry = unlockRetry, pendingUnlock == nil else { return }
        let elapsed = Date().timeIntervalSince(retry.sentAt)
        guard elapsed <= Self.unlockRetryWindow else {
            skipUnlockRetry(String(format: "离第一次发出已经 %.0f 秒，过了电脑这次提示的有效期，不补发", elapsed))
            return
        }
        // 下面几样要等重新连上、读完 INFO、收到心跳才知道
        guard phase == .connected, subscribed, infoRead, let state = computerState else { return }
        if let session = unlockReportSessionNonce, session != retry.session {
            skipUnlockRetry("电脑端重启过（认证会话变了），不补发")
            return
        }
        guard Self.unlockTarget(retry.promptID, matches: state, promptID) else {
            skipUnlockRetry(state == ComputerState.unlocked ? "电脑已经解锁了，不用补发"
                            : retry.promptID == UnlockProtocol.manualPromptID
                                ? "电脑已经不是锁着等手动解锁（\(ComputerState.label(state))），不补发"
                                : "电脑已经不在请这次提示（\(ComputerState.label(state))\(promptID.map { " id=\($0)" } ?? "")），不补发")
            return
        }
        guard unlockReady else { return }  // 认证报告还没通过等，等下一次心跳
        unlockRetry = nil
        let token = UUID()
        pendingUnlock = PendingUnlock(token: token, promptID: retry.promptID, step: .readingChallenge,
                                      automatic: retry.automatic, retry: true)
        unlockBusy = true
        unlockStatus = "重新连上了，正在补发一次解锁请求…"
        record("unlock_retry", note: String(format: "id=%d，第一次发出后连接断了、结果未确认；电脑还在请这次提示，%.1f 秒后用新的一次性签名补发一次",
                                            Int(retry.promptID), elapsed) + (retry.automatic ? "" : "（用户点了解锁的请求）"))
        readUnlockChallenge(token, promptID: retry.promptID)
    }

    private func skipUnlockRetry(_ reason: String) {
        guard let retry = unlockRetry else { return }
        unlockRetry = nil
        record("unlock_retry_skip", note: "id=\(retry.promptID)，\(reason)")
    }

    func setSimulateUnlockDrop(_ on: Bool) {
        simulateUnlockDrop = on
        record("unlock_test", note: on ? "打开假装断线：下一次签好名的解锁请求先不发，直接断开连接" : "关掉假装断线")
    }

    /// 每个会话/提示只自动尝试一次；手机重启、断连和重新订阅不重试（断线后补发另见「解锁请求补发」），电脑新会话同编号可尝试。
    private func attemptAutomaticUnlock() {
        guard automaticUnlockEnabled, canRequestUnlock, let currentID = promptID,
              let sessionNonce = unlockReportSessionNonce else { return }
        let attempt = AutomaticUnlockAttempt(session: sessionNonce.base64EncodedString(), promptID: currentID)
        guard attempt != lastAutomaticUnlockAttempt else { return }
        guard UnlockPreferences.markAutomaticAttempt(attempt, for: key) else {
            unlockStatus = "无法保存本次解锁记录，自动解锁已停止。"
            return
        }
        lastAutomaticUnlockAttempt = attempt
        let token = UUID()
        pendingUnlock = PendingUnlock(token: token, promptID: currentID, step: .readingChallenge, automatic: true)
        unlockBusy = true
        unlockStatus = "手机已靠近，正在自动解锁这台电脑…"
        record("unlock_auto_attempt", note: "id=\(currentID)，此提示只自动尝试一次")
        readUnlockChallenge(token, promptID: currentID)
    }

    /// 只允许首页锁按钮、详情页按钮或通知的明确动作进入；普通心跳永远不会调用。
    /// 电脑在请提示就按这次提示解；只是锁着（没在请提示）时手动解锁，编号 0（通知带着编号，不走手动）
    func requestUnlock(promptID requestedID: UInt16? = nil) {
#if targetEnvironment(simulator)
        if isSimulated {
            simulateAction(unlock: true)
            return
        }
#endif
        let currentID: UInt16
        if canRequestUnlock, let id = promptID, requestedID == nil || requestedID == id {
            currentID = id
        } else if requestedID == nil, canManualUnlock, computerState == ComputerState.locked {
            currentID = UnlockProtocol.manualPromptID
        } else {
            unlockStatus = unlockBusy ? "本次解锁正在处理，请等待结果。"
                : supportsManual ? "现在解锁不了：要连着电脑、登记过解锁，电脑锁着屏。" : "当前没有可确认的解锁提示，请检查连接和登记。"
            showFeedback(unlockStatus ?? "", failed: true)
            return
        }
        // 不要 Face ID：能打开 App 说明手机已经解锁了，和自动解锁一样直接发签名请求
        let token = UUID()
        pendingUnlock = PendingUnlock(token: token, promptID: currentID, step: .readingChallenge, automatic: false)
        unlockBusy = true
        record("unlock_manual", note: currentID == UnlockProtocol.manualPromptID
               ? "手动解锁（电脑锁着、没在请提示），用户点了解锁" : "id=\(currentID)，用户点了解锁")
        readUnlockChallenge(token, promptID: currentID)
    }

    private func readUnlockChallenge(_ token: UUID, promptID currentID: UInt16) {
        guard pendingUnlock?.token == token,
              phase == .connected, subscribed, supportsUnlock,
              Self.unlockTarget(currentID, matches: computerState, promptID),
              let p = peripheral, let challenge = unlockChallengeChar else {
            finishUnlock("电脑状态或连接已变化，本次请求已取消。", result: "读取前状态已变化")
            return
        }
        pendingUnlock?.step = .readingChallenge
        guard beginUnlockBackgroundTask(token) else {
            finishUnlock("系统未提供处理解锁所需的后台时间，本次操作已停止。", result: "无法申请解锁后台时间，没有自动重试")
            return
        }
        unlockReadOutstanding = true
        unlockStatus = "正在核对电脑的解锁请求…"
        armUnlockTimeout(token, step: .readingChallenge, seconds: 30)
        p.readValue(for: challenge)
    }

    private func beginUnlockBackgroundTask(_ token: UUID) -> Bool {
        if unlockBackgroundTask != .invalid { return unlockBackgroundToken == token }
        unlockBackgroundToken = token
        unlockBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "authenticated-mac-unlock") { [weak self] in
            guard let self, self.unlockBackgroundToken == token else { return }
            guard let request = self.pendingUnlock, request.token == token else {
                self.endUnlockBackgroundTask()
                return
            }
            if request.step == .writingCommand {
                self.finishUnlock("后台处理时间已用尽，解锁结果尚未确认，请查看电脑；不会自动重试。",
                                  result: "后台时间到期，已发送请求的结果未知，没有自动重试")
            } else {
                self.finishUnlock("系统后台处理时间已用尽，本次解锁已停止，不会自动重试。",
                                  result: "后台时间到期，尚未发送解锁命令")
            }
        }
        if unlockBackgroundTask == .invalid { unlockBackgroundToken = nil }
        return unlockBackgroundTask != .invalid
    }

    private func endUnlockBackgroundTask() {
        let task = unlockBackgroundTask
        unlockBackgroundTask = .invalid
        unlockBackgroundToken = nil
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    private func armUnlockTimeout(_ token: UUID, step: UnlockStep, seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.pendingUnlock?.token == token, self.pendingUnlock?.step == step else { return }
            self.finishUnlock(step == .writingCommand
                              ? "解锁结果尚未返回，请查看电脑；本次不会自动重试。"
                              : "解锁请求超时，已停止本次操作。", result: "请求超时，没有自动重试")
        }
    }

    private func finishUnlock(_ message: String, result: String, succeeded: Bool = false) {
        let old = pendingUnlock
        pendingUnlock = nil
        unlockBusy = false
        unlockStatus = message
        endUnlockBackgroundTask()
        if let old { record("unlock_result", note: "id=\(old.promptID)，\(result)") }
        if let old, !old.automatic { showFeedback(message, failed: !succeeded) }
    }

    /// linkReset：连接断了或电脑端服务变了（resetLink），已发出的请求可以补发一次
    private func cancelUnlock(_ message: String, linkReset: Bool = false) {
        guard let request = pendingUnlock else {
            endUnlockBackgroundTask()
            return
        }
        if request.step == .writingCommand {
            // 已交给系统的 GATT 写入不能撤回，不能把丢失应答说成电脑没有执行。
            if linkReset, !request.retry, let session = unlockReportSessionNonce {
                unlockRetry = UnlockRetry(promptID: request.promptID, session: session,
                                          automatic: request.automatic, sentAt: request.sentAt ?? Date())
                finishUnlock("连接断了，解锁结果尚未确认；重新连上后如果电脑还在请这次解锁，会补发一次。",
                             result: "连接断了，已发送请求的结果未确认；重新连上后电脑还在请这次提示就补发一次")
            } else {
                finishUnlock("连接或状态已变化，解锁结果尚未确认，请查看电脑；不会自动重试。",
                             result: request.retry ? "补发的请求结果也未确认，不再补发" : "已发送请求的结果未确认，没有自动重试")
            }
        } else {
            finishUnlock(message, result: "请求取消，没有自动重试")
        }
    }

    private func refreshUnlockPrompt() {
        guard let state = computerState else { return }
        owner.prompter.update(computer: key, computerState: state, promptID: promptID,
                              computerName: name, allowsUnlock: supportsUnlock && hasUnlockEnrollment && infoRead
                                && unlockTransportReady && authenticatedReportsReady,
                              automaticUnlock: automaticUnlockEnabled)
    }

    private func onUnlockChallenge(_ data: Data?, error: Error?) {
        unlockReadOutstanding = false
        guard let request = pendingUnlock, request.step == .readingChallenge else { return }
        guard error == nil, let data else {
            finishUnlock("电脑未提供可用的解锁挑战。", result: "读取挑战失败")
            return
        }
        guard supportsUnlock, hasUnlockEnrollment,
              Self.unlockTarget(request.promptID, matches: computerState, promptID),
              let p = peripheral, p.state == .connected, let command = unlockCommandChar else {
            finishUnlock("电脑状态或连接已变化，本次请求已取消。", result: "签名前状态已变化")
            return
        }
        do {
            guard let enrollment = try UnlockKeychain.load(key) else {
                hasUnlockEnrollment = false
                throw UnlockAuthorizationError.invalidEnrollment
            }
            let payload = try enrollment.request(challenge: data, expectedPromptID: request.promptID,
                                                 manual: request.promptID == UnlockProtocol.manualPromptID)
            guard command.properties.contains(.write), p.maximumWriteValueLength(for: .withResponse) >= payload.count else {
                finishUnlock("电脑不支持有回复的解锁请求。", result: "解锁特征不支持写回复")
                return
            }
            pendingUnlock?.step = .writingCommand
            pendingUnlock?.sentAt = Date()
            if simulateUnlockDrop && !request.retry {
                // 测试：当作已经发出（结果未确认），其实不发，直接断开，走一遍补发
                simulateUnlockDrop = false
                record("unlock_test", note: "id=\(request.promptID)，假装断线：签名请求没发出去，主动断开连接")
                selfDropReason = "测试：假装断线"
                central.cancelPeripheralConnection(p)
                return
            }
            unlockWriteOutstanding = true
            unlockStatus = "电脑正在验证并解锁…"
            record("unlock_sent", note: "id=\(request.promptID)，" + (request.retry ? "已补发一次签名请求" : "已发送一次签名请求"))
            armUnlockTimeout(request.token, step: .writingCommand, seconds: 30)
            p.writeValue(payload, for: command, type: .withResponse)
        } catch {
            finishUnlock(error.localizedDescription, result: "无法准备签名请求")
        }
    }

    private func onUnlockWritten(_ error: Error?) {
        unlockWriteOutstanding = false
        guard pendingUnlock?.step == .writingCommand else { return }
        if let error = error as NSError? {
            let reason: String
            switch error.domain == CBATTErrorDomain ? error.code : -1 {
            case 0x80: reason = pendingUnlock?.promptID == UnlockProtocol.manualPromptID
                ? "电脑现在不接受手动解锁（已经解锁了，或者连接还没认证好）" : "电脑上的解锁提示已失效"
            case 0x81: reason = "解锁登记不匹配，请重新登记"
            case 0x82: reason = "解锁挑战已过期或已使用"
            case 0x83: reason = "电脑未能完成解锁，请在电脑上检查密码和辅助功能权限"
            default: reason = "电脑未接受解锁请求，请检查连接"
            }
            finishUnlock(reason + "；本次不会自动重试。", result: reason)
        } else {
            finishUnlock("电脑已确认解锁。", result: "电脑确认已解锁", succeeded: true)
        }
    }

    private var central: CBCentralManager { owner.central }

    // MARK: - LinkManager 调用

    /// 系统在后台拉起 App 时交回来的外设（willRestoreState）
    func restore(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
    }

    /// 蓝牙打开了（包括刚启动）：接上恢复的连接，或者按记住的 identifier 取回外设、挂上连接请求
    func resume() {
        if let p = peripheral {
            if p.state == .connected {
                record("restored_connected", note: "id=\(p.identifier.uuidString)")
                setup(p)
            } else {
                connect(p)
            }
            return
        }
        if let p = central.retrievePeripherals(withIdentifiers: [savedID]).first {
            connect(p)
        } else {
            record("retrieve_failed", note: "系统找不到 id=\(savedID.uuidString)，只能靠搜索")
            phase = .searching
        }
    }

    func bluetoothUnavailable(_ state: CBManagerState) {
        // 蓝牙关掉时系统直接断开所有连接，不会回调 didDisconnect，这里按断开处理
        if phase == .connected { linkLost("蓝牙\(state.label)") }
        phase = .bluetoothUnavailable
        // 蓝牙关掉以后原来的外设对象都失效了，重新打开时按记住的 id 重新取
        if state != .unknown { peripheral = nil }
    }

    /// 搜索搜到了记住的 identifier：系统没能取回它（retrieve_failed）时才需要在这里连
    func discovered(_ p: CBPeripheral) {
        if peripheral == nil { connect(p) }
    }

    /// 刚添加：搜索时为了读名字已经连上的就直接用，没连上的挂连接请求
    func take(_ p: CBPeripheral) {
        if p.state == .connected {
            record("connect", note: "id=\(p.identifier.uuidString)，读名字时已经连上")
            setup(p)
        } else {
            connect(p)
        }
    }

    /// 核对通过：电脑换了地址，改连这台，更新记住的 identifier
    func adopt(_ p: CBPeripheral) {
        let old = peripheral
        peripheral = p  // 先换掉，取消旧的连接请求时 didDisconnect 不会再把它连回来
        if let old, old !== p { central.cancelPeripheralConnection(old) }
        savedID = p.identifier
        owner.saveComputers()
        var note = "电脑换了 identifier：\(old?.identifier.uuidString ?? "无") → id=\(p.identifier.uuidString)"
        if let at = disconnectedAt {
            let s = Date().timeIntervalSince(at)
            owner.stats.lastReconnectSeconds = s
            note += String(format: "，断开 %.1f 秒后重连", s)
            disconnectedAt = nil
        }
        record("adopt", note: note)
        setup(p)
    }

    /// 「忘记这台电脑」：断开、不再重连。LinkManager 把它从列表里去掉
    func forget() {
        record("forget", note: "id=\((peripheral?.identifier ?? savedID).uuidString)")
        do { try removeUnlockEnrollment() }
        catch { record("unlock_enrollment_delete_error", note: "钥匙串删除失败，请在手机解锁后重试") }
        let p = peripheral
        peripheral = nil
        pendingReportWrite = nil
        resetLink()
        endBackgroundTask()
        simTimer?.invalidate()
        if let p {
            p.delegate = nil
            central.cancelPeripheralConnection(p)
        }
    }

    /// 「重新连接」：断开再连，配对被取消或出错以后用它重新触发配对
    func reconnect() {
        guard let p = peripheral else { return }
        record("reconnect", note: "用户点了重新连接")
        linkProblem = nil
        encryptTimeoutAt = nil
        let wasConnected = p.state == .connected
        if p.state != .disconnected { central.cancelPeripheralConnection(p) }
        // 已连接的会回调 didDisconnect，在那里重连；没连上的直接重新挂连接请求
        if !wasConnected { connect(p) }
    }

    func apply(_ settings: JudgeSettings) {
        judge.settings = settings
    }

    // MARK: - 连接

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        phase = .connecting
        central.connect(p, options: nil)
        record("connect_request", note: "id=\(p.identifier.uuidString)")
    }

    private func setup(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        phase = .connected
        serviceMissingSince = nil
        infoRead = false
        infoReading = nil
        supportsUnlock = false
        lastDiscoveredUnlockTransport = nil
        lastDiscoveredUnlockService = nil
        pendingReportWrite = nil
        invalidateUnlockReportSession()
        startDiscovery(p)
    }

    func didConnect(_ p: CBPeripheral) {
        if let at = droppedForServiceAt {
            droppedForServiceAt = nil
            if Date().timeIntervalSince(at) < 2 {
                dropDoesNothing = true
                record("no_service_wait", note: "主动断开后系统马上又连上了（链路没断），之后不再断开，一直等服务回来")
            }
        }
        var note = "id=\(p.identifier.uuidString)"
        if let at = disconnectedAt {
            let s = Date().timeIntervalSince(at)
            owner.stats.lastReconnectSeconds = s
            note += String(format: "，断开 %.1f 秒后重连", s)
            disconnectedAt = nil
        }
        record("connect", note: note)
        encryptTimeoutAt = nil
        setup(p)
    }

    func didFailToConnect(_ p: CBPeripheral, error: Error?) {
        record("connect_fail", note: error?.localizedDescription ?? "")
        // 加密超时：Windows 用电池待机时，手机回来第一次连上常常这样，链路两三秒后就自己连回来了，
        // 原来当成配对问题等 10 秒，白等 7 到 9 秒。
        // 第一次马上重新挂连接请求（不靠定时器，App 在后台被挂起时定时器不走），60 秒内又超时才当成配对问题
        if isEncryptionTimeout(error), peripheral === p {
            let now = Date()
            let first = encryptTimeoutAt.map { now.timeIntervalSince($0) > Self.encryptRetryWindow } ?? true
            encryptTimeoutAt = now
            if first {
                record("encrypt_retry", note: "加密超时，马上重连；60 秒内再超时才放慢到 10 秒、提示配对问题")
                connect(p)
                return
            }
        }
        notePairingProblem(error)
        // 配对出问题时每次都会马上失败，放慢重试，免得日志刷屏
        let delay: Double = pairingHint(error) == nil ? 2 : 10
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // 排着的重试到点时可能已经连上了（系统恢复时一次连接请求可能回两次失败，排了两条），
            // 再连一次会把发现服务重来一遍
            guard let self, self.peripheral === p, p.state == .disconnected, self.central.state == .poweredOn else { return }
            self.connect(p)
        }
    }

    func didDisconnect(_ p: CBPeripheral, error: Error?) {
        if droppedForServiceAt == nil { dropDoesNothing = false }
        // 没连上时也可能收到（比如取消读名字的连接时刚好添加了它），那时不算一次断开
        if phase == .connected {
            linkLost(selfDropReason ?? error?.localizedDescription ?? "正常断开")
        }
        selfDropReason = nil
        notePairingProblem(error)
        // 立即挂起一个新的连接请求：它不会超时，手机回到范围内系统自动连上。
        // 电脑可能换了地址，phase 变成 connecting 后 LinkManager 会同时按服务 UUID 搜索
        connect(p)
    }

    // MARK: - 发现服务
    //
    // 同时只发现一轮，发现完才订阅心跳、读 INFO。发现的过程中服务又变了，就等这一轮回来再发现一次，不另起一轮。
    // INFO 每条连接只读一次，电脑端程序重启后服务回来再读一次。
    // 原来连上、服务变化、等服务的 3 秒重试各起一轮，几轮叠在一起各订阅、各读一次：
    // 连上 Windows 时它马上发服务变化，订阅和 INFO 常常各 2 到 3 次；服务回来时还碰到过 3 秒里读了 12 次 INFO，
    // 因为等服务的几分钟里 Windows 发了二十多次服务变化，每次没找到服务都多排一条 3 秒重试，攒下了 12 条。
    // Windows 端每次读 INFO 都是一次跨进程 WinRT 调用，以前就卡死过，不该一连读十几次。

    /// 要重新发现：正在发现就等这一轮回来再来一次
    private func requestDiscovery(_ p: CBPeripheral) {
        if discovery == .idle {
            startDiscovery(p)
        } else {
            rediscover = true
        }
    }

    private func startDiscovery(_ p: CBPeripheral) {
        resetLink()
        discovery = .services
        // 发现加订阅 40 秒没完成就断开重连（只发现一轮，卡住了不会有新的一轮来顶）；等服务时由 onServiceMissing 管
        if serviceMissingSince == nil {
            armWatchdog(Self.subscribeTimeout, "发现服务、订阅心跳 \(Int(Self.subscribeTimeout)) 秒没完成")
        }
        p.discoverServices([Proto.service])
    }

    // MARK: - 电脑端程序停了，但蓝牙连接还在
    //
    // 实测：win_peer.py 重启时 Windows 不断开蓝牙连接，只是服务没了，
    // 原来的 App 就停在「已连接、没有心跳」上，等了 5 分半直到手机关开蓝牙。
    // 现在每 3 秒重新找一次服务（程序重新启动后服务在同一个连接上就能找到）；
    // 30 秒还没有就主动断开，走正常的重连和「换了地址」兜底。
    // 实测配对后主动断开也没用：系统不放链路，连接请求 0 秒就又连上了。这时只断一次，
    // 之后一直连着等：前台每 3 秒找一次，后台靠电脑加服务时发的服务变化通知（didModifyServices）。

    private static let serviceRetryInterval = 3.0
    private static let serviceWaitLimit = 30.0

    private func onServiceMissing(_ p: CBPeripheral, _ note: String) {
        let now = Date()
        if serviceMissingSince == nil {
            serviceMissingSince = now
            infoRead = false  // 服务回来时是新启动的程序，再读一次 INFO
            invalidateUnlockReportSession()
            record("no_service", note: note)
            disarmWatchdog()  // 没服务时由这里管，看门狗不插手
            beginBackgroundTask()
        }
        if let since = serviceMissingSince, now.timeIntervalSince(since) >= Self.serviceWaitLimit {
            if dropDoesNothing {
                endBackgroundTask()  // 不再断开，也不再占后台时间；前台的轮询照常
            } else {
                record("no_service_drop", note: "等了 \(Int(Self.serviceWaitLimit)) 秒服务还没回来，断开重连")
                serviceMissingSince = nil
                droppedForServiceAt = now
                selfDropReason = "等不到服务，主动断开"
                endBackgroundTask()
                central.cancelPeripheralConnection(p)  // didDisconnect 里会重新挂连接请求、开始兜底搜索
                return
            }
        }
        // 只排一条：原来每次没找到都排一条，服务变化又多触发几次发现，重试越攒越多（见上面「发现服务」）
        guard !serviceRetryScheduled else { return }
        serviceRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.serviceRetryInterval) { [weak self] in
            guard let self else { return }
            self.serviceRetryScheduled = false
            // 正在发现（比如服务变化触发的）就不用再找，那一轮没找到会再排下一次
            guard p === self.peripheral, p.state == .connected, self.serviceMissingSince != nil,
                  self.discovery == .idle else { return }
            self.startDiscovery(p)
        }
    }

    // MARK: - 心跳看门狗
    //
    // Windows 电脑端会卡死，守护进程把它重启以后是一个全新的服务，但蓝牙连接没断，
    // App 收不到断开事件，就停在「正在订阅心跳」，或者订阅着旧服务再也收不到心跳
    // （docs/protocol.md 第 1、4 个问题）。所以连上以后一直盯着心跳：订阅 40 秒没完成，
    // 或者 5 秒没收到心跳，就断开再连，强制重新发现服务、重新订阅。
    // 电脑心跳放慢、休眠时（v1.2），每次心跳都写明下一次最晚几秒后到，按它再多等 3 秒。
    // 连续触发时等待时间翻倍（最多 60 秒，休眠时一次就到 60 秒），免得电脑真卡住时一直重连；收到心跳就复位。
    // 后台时检查只在 App 被蓝牙事件唤醒的那几秒里能跑，心跳一停，最后一次心跳排下的检查通常还来得及触发。
    // 连着几台电脑时，别的电脑的心跳也会唤醒 App，检查更准时。

    private static let heartbeatTimeout = 5.0
    /// 宣布的间隔之外再多等几秒：读 RSSI、蓝牙排队、App 在后台被叫醒都要时间
    private static let heartbeatGrace = 3.0
    private static let subscribeTimeout = 40.0  // 订阅时可能正在弹配对请求，多给点时间
    /// 宣布的间隔到这么长就算电脑在休眠，被 iBeacon 区域事件叫醒时主动报一次信号
    private static let dormantInterval = 10

    /// 多久没收到心跳算停了：电脑宣布的「下一次最晚几秒」加 3 秒，至少 5 秒；v1 电脑端没宣布，按 5 秒
    private var heartbeatBase: Double {
        max(Self.heartbeatTimeout, announcedInterval.map { Double($0) + Self.heartbeatGrace } ?? 0)
    }

    private var currentHeartbeatTimeout: Double {
        min(max(60, heartbeatBase), heartbeatBase * Double(1 << min(watchdogResets, 4)))
    }

    private func armWatchdog(_ seconds: Double, _ reason: String) {
        watchdogGeneration += 1
        let generation = watchdogGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, generation == self.watchdogGeneration else { return }
            self.watchdogFired(reason)
        }
    }

    private func disarmWatchdog() {
        watchdogGeneration += 1
    }

    private func armHeartbeatWatchdog(_ what: String) {
        let seconds = currentHeartbeatTimeout
        armWatchdog(seconds, String(format: "%@ %.0f 秒没收到心跳", what, seconds))
    }

    private func watchdogFired(_ reason: String) {
        guard let p = peripheral, phase == .connected, serviceMissingSince == nil else { return }
        watchdogResets += 1
        // 协议服务不止一个时，下一轮换一个用（订阅在旧服务上「成功」时不会有错误来触发换服务）
        if serviceCount > 1 { serviceIndex += 1 }
        record("hb_timeout", note: "\(reason)，断开重连（连续第 \(watchdogResets) 次）"
               + (serviceCount > 1 ? "，下一轮换第 \(serviceIndex % serviceCount + 1) 个协议服务" : ""))
        selfDropReason = "心跳超时，主动断开"
        beginBackgroundTask()  // 后台时撑到重新订阅完
        central.cancelPeripheralConnection(p)  // didDisconnect 里重新挂连接请求
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "wait-service") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func resetLink() {
        cancelUnlock("连接服务已变化，本次解锁请求已停止。", linkReset: true)
        resetAuthenticatedReportConfirmation()
        discovery = .idle
        rediscover = false
        staleThisRound = false
        subscribed = false
        heartbeatChar = nil
        reportChar = nil
        infoChar = nil
        unlockChallengeChar = nil
        unlockCommandChar = nil
        enrollAckChar = nil
        enrollRequestChar = nil
        lockCommandChar = nil
        if lockToken != nil {
            finishLock("连接断了，没收到锁屏结果，请看一下电脑。", failed: true, result: "连接断了，锁屏结果未确认")
        }
        unlockTransportReady = false
        unlockReadOutstanding = false
        unlockWriteOutstanding = false
        reading = nil
        waiting = nil
        disarmWatchdog()
        refreshUnlockPrompt()
    }

    private func linkLost(_ note: String) {
        owner.stats.disconnects += 1
        disconnectedAt = Date()
        resetLink()
        pendingReportWrite = nil
        invalidateUnlockReportSession()
        lastDiscoveredUnlockService = nil
        serviceMissingSince = nil
        computerState = nil
        endBackgroundTask()
        record("disconnect", note: note)
        if let reason = judge.disconnected() {
            phoneState = judge.state
            record("state", state: judge.state, note: reason)
        }
    }

    // MARK: - 配对

    /// 和配对有关、要用户处理的错误，返回界面上的提示
    private func pairingHint(_ error: Error?) -> String? {
        guard let error = error as NSError? else { return nil }
        if error.domain == CBErrorDomain {
            switch CBError.Code(rawValue: error.code) {
            case .peerRemovedPairingInformation:
                return "电脑那边删掉了配对。去 iPhone「设置 → 蓝牙」里找到这台电脑，点 ⓘ →「忽略此设备」，再点「重新连接」。"
            case .encryptionTimedOut:
                return "加密超时，配对可能没完成。点「重新连接」再试一次。"
            default:
                return nil
            }
        }
        if error.domain == CBATTErrorDomain {
            switch CBATTError.Code(rawValue: error.code) {
            case .insufficientAuthentication, .insufficientEncryption, .insufficientEncryptionKeySize:
                return "电脑要求配对。在弹出的「蓝牙配对请求」里点「配对」；点了取消的话，点「重新连接」再弹一次。"
            default:
                return nil
            }
        }
        return nil
    }

    private func isEncryptionTimeout(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == CBErrorDomain else { return false }
        return CBError.Code(rawValue: error.code) == .encryptionTimedOut
    }

    private func notePairingProblem(_ error: Error?) {
        guard let hint = pairingHint(error) else { return }
        if linkProblem != hint { record("pairing_problem", note: hint) }
        linkProblem = hint
    }

    // MARK: - 旧服务
    //
    // Windows 电脑端重启后（手机日志里碰到过几次），iPhone 和 Windows 的链路一直没断，
    // App 重新发现服务、订阅，结果是：订阅「成功」但没有心跳、读 INFO 回 Unlikely error（Windows 上没有程序处理这个服务），
    // 或者订阅、读 INFO 都回「句柄无效」（iPhone 记着旧的服务结构）。收到服务变化通知、重新发现也一样，
    // 看门狗断开重连也断不掉链路（配对过的电脑系统不放），只有手机关开一次蓝牙才好。
    // 推测 iPhone 的缓存里留着旧进程的那份服务，和新的同一个 UUID，App 原来总拿第一个。
    // 所以：发现到不止一个协议服务时记下来，碰到这两种错误就换下一个；只有一个、或者换遍了还不行，
    // 连续两轮以后提示用户关开蓝牙（App 在后台时弹通知）。收到心跳就都复位。

    static let staleHint = "iPhone 还记着这台电脑旧的服务，订阅不上（电脑端程序重启过）。去 iPhone「设置 → 蓝牙」关掉再打开一次。"

    /// 句柄无效：iPhone 记着旧的服务结构；Unlikely error：Windows 上没有程序处理这个服务
    private static func isStale(_ error: Error?) -> Bool {
        guard let e = error as NSError?, e.domain == CBATTErrorDomain else { return false }
        return e.code == CBATTError.invalidHandle.rawValue || e.code == CBATTError.unlikelyError.rawValue
    }

    private func onStale(_ p: CBPeripheral, _ what: String) {
        guard !staleThisRound else { return }
        staleThisRound = true
        staleRounds += 1
        if serviceCount > 1 && serviceSwitches < serviceCount - 1 {
            serviceSwitches += 1
            serviceIndex += 1
            record("service_switch", note: "\(what)碰到旧服务的错误，换第 \(serviceIndex % serviceCount + 1) 个协议服务（一共 \(serviceCount) 个）")
            requestDiscovery(p)
            return
        }
        guard staleRounds >= 2 else { return }
        if linkProblem != Self.staleHint {
            record("stale_service", note: "连续 \(staleRounds) 轮\(what)碰到旧服务的错误，协议服务 \(serviceCount) 个，提示关开蓝牙")
        }
        linkProblem = Self.staleHint
        if !staleNotified {
            staleNotified = true
            owner.prompter.showLinkProblem(key, computerName: name, body: Self.staleHint)
        }
    }

    /// 收到心跳：旧服务的问题过去了
    private func staleResolved() {
        staleRounds = 0
        serviceSwitches = 0
        if linkProblem == Self.staleHint { linkProblem = nil }
        if staleNotified {
            staleNotified = false
            owner.prompter.removeLinkProblem(key)
            record("stale_resolved", note: "心跳恢复了，撤掉关开蓝牙的提示")
        }
    }

    // MARK: - 心跳 → RSSI → REPORT

    private func onHeartbeat(_ hb: Heartbeat) {
        let seq = hb.seq
        let now = Date()
        if supportsUnlock, let previous = lastSeq, seq < previous {
            // 有的系统会沿用服务对象；心跳序号回退同样说明不能再信任缓存的进程会话。
            infoRead = false
            infoReading = nil
            invalidateUnlockReportSession()
            record("unlock_session_refresh", note: "心跳序号回退，重新读取本次电脑会话")
            if let p = peripheral, let c = infoChar {
                infoReading = c
                p.readValue(for: c)
            }
        }
        onComputerState(hb)
        onAnnouncedInterval(hb, seq: seq)
        updateAuthenticatedReportsReady()
        attemptUnlockRetry()
        attemptAutomaticUnlock()
        owner.stats.heartbeats += 1
        var note = ""
        if let last = lastSeq {
            if seq > last &+ 1 {
                let n = Int(seq - last - 1)
                owner.stats.missed += n
                note = "漏了 \(n) 次心跳"
            } else if seq <= last {
                owner.stats.seqResets += 1
                note = "seq 从 \(last) 变成 \(seq)，电脑端可能重启了"
            }
        }
        lastSeq = seq
        lastHeartbeatAt = now
        if watchdogResets > 0 {
            record("hb_back", note: "看门狗重连后心跳恢复了")
            watchdogResets = 0
        }
        if staleRounds > 0 || staleNotified { staleResolved() }
        armHeartbeatWatchdog("已经")
        let read = PendingRead(seq: seq, at: now, note: note)
        guard reading == nil else {
            if let dropped = waiting {
                owner.stats.skipped += 1
                record("skip", seq: dropped.seq, note: "上一次 RSSI 还没读完，这次心跳不回 REPORT")
            }
            waiting = read
            return
        }
        startRead(read)
    }

    /// 电脑状态变了记一行；状态 3 + 新编号弹通知、不再是 3 撤掉通知交给 UnlockPrompter（每台电脑一条通知）
    private func onComputerState(_ hb: Heartbeat) {
        if let request = pendingUnlock, !Self.unlockTarget(request.promptID, matches: hb.computerState, hb.promptID) {
            if request.step == .writingCommand && hb.computerState == ComputerState.unlocked {
                // 普通心跳的锁屏检测可能暂时未知；只有 UNLOCK 的写回复才确认本次认证结果。
                unlockStatus = "电脑状态已变化，正在等待解锁结果…"
            } else {
                cancelUnlock("电脑状态已变化，本次解锁请求已取消。")
            }
        }
        if hb.computerState != computerState || hb.promptID != promptID {
            let old = computerState.map(ComputerState.label) ?? "无"
            record("host_state", note: "\(old) → \(ComputerState.label(hb.computerState))"
                   + (hb.promptID.map { " id=\($0)" } ?? "，v0 电脑端没有提示编号"))
            computerState = hb.computerState
            promptID = hb.promptID
        }
        refreshUnlockPrompt()
    }

    /// 心跳宣布的间隔变了记一行，和电脑端的 hb_rate 对时间；看门狗按新的间隔算
    private func onAnnouncedInterval(_ hb: Heartbeat, seq: UInt32) {
        let next = hb.nextWithin.map { max(1, Int($0)) }
        guard next != announcedInterval else { return }
        let text = { (s: Int?) in s.map { "\($0) 秒" } ?? "没写" }
        let old = text(announcedInterval)
        announcedInterval = next
        record("hb_interval", seq: seq, note: "电脑宣布下一次心跳最晚几秒后到：\(old) → \(text(next))"
               + (dormant ? "（休眠）" : next == nil ? "（v1 电脑端）" : "") + String(format: "，看门狗按 %.0f 秒", heartbeatBase))
    }

    // MARK: - 休眠时主动报告
    //
    // 电脑休眠时 30 秒才发一次心跳（docs/protocol.md「心跳快慢和休眠」），人拿起手机走回电脑时，
    // 电脑最慢要 30 秒才知道信号变强了。所以被 iBeacon 区域事件叫醒（在区域里亮屏、进入区域）时，
    // 对休眠的电脑主动读一次 RSSI、写一条 REPORT（seq 用最近一次心跳的），电脑看到 ≥ -75 就马上恢复每秒一次。
    // 不在休眠的电脑每秒、每 3 秒都有心跳，不用多报。

    /// 主动报一次。没连着、没订阅上、电脑没在休眠、正在读 RSSI（读完自然会报）时不报，返回 false
    @discardableResult
    func wakeReport(_ reason: String) -> Bool {
        guard phase == .connected, subscribed, reportChar != nil, dormant, reading == nil,
              let seq = lastSeq else { return false }
        startRead(PendingRead(seq: seq, at: Date(), note: "主动报告：\(reason)", wake: true))
        return true
    }

    private func startRead(_ read: PendingRead) {
        reading = read
        peripheral?.readRSSI()
    }

    private func onRSSI(_ value: Int?, error: Error?) {
        guard let pending = reading else { return }
        reading = nil
        defer {
            if let next = waiting {
                waiting = nil
                startRead(next)
            }
        }
        let now = Date()
        if let value {
            lastRSSI = value
            samples.append(RSSISample(time: now, rssi: value))
            samples.removeAll { now.timeIntervalSince($0.time) > 180 }
            owner.notePlaceRSSI(value, for: key)
        } else {
            owner.stats.rssiFailed += 1
        }
        if let reason = judge.feed(value, at: now) {
            phoneState = judge.state
            record("state", state: judge.state, note: reason)
        }
        sendReport(seq: pending.seq, rssi: value)
        var note = pending.note
        if let error { note += (note.isEmpty ? "" : "；") + "读 RSSI 失败：\(error.localizedDescription)" }
        // 手机端的 latency_ms：从收到心跳（主动报告是从开始读）到读到 RSSI 用了多久
        record(pending.wake ? "report_wake" : "report", seq: pending.seq, rssi: value ?? Int(Proto.rssiUnavailable),
               state: judge.state, latencyMs: Int((now.timeIntervalSince(pending.at) * 1000).rounded()), note: note)
    }

    private func sendReport(seq: UInt32, rssi: Int?) {
        guard let p = peripheral, let c = reportChar else { return }
        // 保持每个句柄最多一个待回复的报告，回复才能准确对应认证会话。
        if pendingReportWrite?.characteristic === c { return }
        let report = Report(seq: seq, rssi: rssi.map { Int8(clamping: $0) } ?? Proto.rssiUnavailable, state: judge.state)
        var payload = report.data
        var authenticated = false
        if infoRead, supportsUnlock, let nonce = unlockReportSessionNonce, let enrollment = unlockEnrollmentCache {
            do {
                payload = try enrollment.authenticatedReport(base: payload, sessionNonce: nonce,
                                                              packetNonce: UnlockEnrollment.randomReportNonce())
                authenticated = true
            } catch {
                // 已具备登记的连接不能因签名失败而降级发送未认证的 RSSI。
                authenticatedReportFailed(error.localizedDescription, detail: "无法生成认证报告，本包未发送")
                return
            }
        }
        if authenticated {
            guard c.properties.contains(.write), p.maximumWriteValueLength(for: .withResponse) >= payload.count else {
                authenticatedReportFailed("当前蓝牙连接无法发送认证报告，自动解锁已暂停，请重新连接。",
                                          detail: "35 字节认证报告超出当前可用写入容量，本包未发送")
                return
            }
            pendingReportWrite = PendingReportWrite(characteristic: c, authenticatedSession: reportPresenceSession, at: Date())
            p.writeValue(payload, for: c, type: .withResponse)
            return
        }
        let canSkipResponse = c.properties.contains(.writeWithoutResponse) && p.canSendWriteWithoutResponse
            && p.maximumWriteValueLength(for: .withoutResponse) >= payload.count
        if !canSkipResponse { pendingReportWrite = PendingReportWrite(characteristic: c, authenticatedSession: nil, at: Date()) }
        p.writeValue(payload, for: c, type: canSkipResponse ? .withoutResponse : .withResponse)
    }

    private func onReportWritten(_ c: CBCharacteristic, error: Error?) {
        guard let write = pendingReportWrite, write.characteristic === c else { return }
        pendingReportWrite = nil
        guard c === reportChar, let session = write.authenticatedSession,
              session == reportPresenceSession else { return }
        if error == nil {
            confirmedAuthenticatedReportAt = write.at
            updateAuthenticatedReportsReady()
            refreshUnlockPrompt()
            // 重新订阅后即使第一条心跳已经是 state3，也要等本连接的认证报告成功再读挑战。
            attemptUnlockRetry()
            attemptAutomaticUnlock()
        } else {
            confirmedAuthenticatedReportAt = nil
            authenticatedReportFailed("电脑未接受认证报告，自动解锁暂不可用。", detail: "认证报告写回复失败，未建立本连接的认证状态")
        }
    }

    private func onInfo(_ data: Data) {
        record("info", note: String(decoding: data, as: UTF8.self))
        guard let info = try? JSONDecoder().decode(ComputerInfo.self, from: data) else {
            supportsUnlock = false
            invalidateUnlockReportSession()
            return
        }
        if let name = info.name, !name.isEmpty, name != self.name || name != infoName {
            self.name = name
            infoName = name
            owner.saveComputers()
        }
        platform = info.platform
        let nonce = info.reportNonce.flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 16 ? $0 : nil }
        if let oldNonce = unlockReportSessionNonce, oldNonce != nonce { invalidateUnlockReportSession() }
        resetAuthenticatedReportConfirmation()
        supportsUnlock = UnlockCapability.supports(platform: info.platform, capability: info.unlock)
        supportsManual = supportsUnlock && (info.manual ?? 0) >= 1
        unlockReportSessionNonce = nonce
        if !supportsUnlock { unlockReportSessionNonce = nil; unlockEnrollmentCache = nil }
        updateAuthenticatedReportsReady()
        refreshUnlockAuthorization()
        refreshUnlockPrompt()
        if let proto = info.proto, proto > Proto.version {
            protoWarning = "电脑端协议版本是 \(proto)，比手机的 \(Proto.version) 新，App 要更新"
        } else {
            protoWarning = nil
        }
        sendEnrollAckIfReady()
    }

    // MARK: - 手机让电脑锁屏
    //
    // 首页锁按钮在电脑没锁屏时用（docs/protocol.md「手动锁屏、解锁」）。和认证报告一样用登记密钥签名，
    // 带最近一次收到的心跳 seq：电脑核对是它刚发过的、包没重放过，不用先读挑战。锁屏和解锁都不要 Face ID。
    // 电脑那边当作用户自己锁的屏：手机一直在旁边不会请提示，回到电脑前要在手机上手动解锁

    func requestLock() {
#if targetEnvironment(simulator)
        if isSimulated {
            simulateAction(unlock: false)
            return
        }
#endif
        guard canRemoteLock, let p = peripheral, let c = lockCommandChar, let seq = lastSeq,
              let nonce = unlockReportSessionNonce, let enrollment = unlockEnrollmentCache else {
            showFeedback(lockBusy ? "正在等电脑回复。" : "现在锁不了：要连着电脑、登记过解锁，电脑端要能接收锁屏命令。", failed: true)
            return
        }
        let payload: Data
        do {
            payload = try enrollment.lockCommand(seq: seq, sessionNonce: nonce, packetNonce: UnlockEnrollment.randomReportNonce())
        } catch {
            showFeedback(error.localizedDescription, failed: true)
            return
        }
        guard c.properties.contains(.write), p.maximumWriteValueLength(for: .withResponse) >= payload.count else {
            showFeedback("电脑不支持有回复的锁屏命令。", failed: true)
            return
        }
        let token = UUID()
        lockToken = token
        lockBusy = true
        record("lock_sent", seq: seq, note: "请电脑锁屏")
        p.writeValue(payload, for: c, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.lockToken == token else { return }
            self.finishLock("锁屏结果没返回，请看一下电脑。", failed: true, result: "10 秒没回复")
        }
    }

    private func onLockWritten(_ error: Error?) {
        guard lockToken != nil else { return }
        guard let error = error as NSError? else {
            finishLock("电脑已锁屏。", failed: false, result: "电脑确认已锁屏")
            return
        }
        let reason: String
        switch error.domain == CBATTErrorDomain ? error.code : -1 {
        case 0x80: reason = "电脑现在不接受锁屏命令（连接还没认证好），过一会儿再试"
        case 0x81: reason = "解锁登记不匹配，请重新登记"
        case 0x82: reason = "锁屏命令过期了，再点一次"
        case 0x83: reason = "电脑没能锁屏"
        default: reason = "电脑没收下锁屏命令，请检查连接"
        }
        finishLock(reason + "。", failed: true, result: reason + "：" + error.localizedDescription)
    }

    private func finishLock(_ message: String, failed: Bool, result: String) {
        lockToken = nil
        lockBusy = false
        showFeedback(message, failed: failed)
        record("lock_result", note: result)
    }

    private func showFeedback(_ text: String, failed: Bool) {
        let feedback = ActionFeedback(text: text, failed: failed, at: Date())
        actionFeedback = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.actionFeedback == feedback { self?.actionFeedback = nil }
        }
    }

    // MARK: - 登记确认
    //
    // 保存登记（扫码或粘贴）以后告诉电脑一声，电脑的登记窗口收到就自己关（docs/protocol.md「登记确认」）。
    // 连着、读过 INFO 就马上发；没连着就下次连上读完 INFO 补发，保存 2 分钟以后不补（窗口多半早关了）。
    // 每次保存只发一次，不重试；电脑没有这个特征（旧版电脑端，或者电脑上还没登记）就不发。发没发成都不影响登记

    private static let enrollAckWindow: TimeInterval = 120

    private func sendEnrollAckIfReady() {
        guard let pending = enrollAckPending else { return }
        if Date().timeIntervalSince(pending.savedAt) > Self.enrollAckWindow {
            enrollAckPending = nil
            record("enroll_ack_skip", note: "保存登记 2 分钟内没连上读完 INFO，不再发登记确认")
            return
        }
        // 正在发现服务时特征值可能马上作废，等这一轮发现完再说
        guard let p = peripheral, p.state == .connected, infoRead, discovery == .idle else { return }
        guard supportsUnlock, let nonce = unlockReportSessionNonce, let char = enrollAckChar else {
            enrollAckPending = nil
            record("enroll_ack_skip", note: "电脑端没有登记确认（旧版电脑端，或者电脑上还没登记、没开解锁），不发")
            return
        }
        enrollAckPending = nil
        do {
            p.writeValue(try pending.enrollment.enrollAck(reportNonce: nonce), for: char, type: .withResponse)
            record("enroll_ack_sent", note: "已发登记确认，电脑的登记窗口收到会自己关")
        } catch {
            record("enroll_ack_fail", note: error.localizedDescription)
        }
    }

    private func onEnrollAckWritten(_ error: Error?) {
        if let error {
            record("enroll_ack_fail", note: "电脑没收下：\(error.localizedDescription)")
        } else {
            record("enroll_ack_ok", note: "电脑收下了登记确认")
        }
    }

    // MARK: - 请电脑显示登记码
    //
    // 点「扫码登记」时顺着连接告诉电脑一声，电脑自己弹出登记窗口，不用再去电脑上运行命令。
    // 电脑上先问一句、点了才显示二维码（docs/protocol.md「手机请求显示登记码」）。电脑端太旧、没有这个特征就照旧

    /// 连着、电脑有这个特征才能请
    var canRequestEnrollmentCode: Bool {
        phase == .connected && peripheral?.state == .connected && enrollRequestChar != nil
    }

    /// 能请就写一次 0x01；不能请就清掉上次的回复，扫码页上改成提示去电脑上打开登记窗口
    func requestEnrollmentCode() {
        guard canRequestEnrollmentCode, let p = peripheral, let char = enrollRequestChar else {
            enrollRequestStatus = nil
            return
        }
        p.writeValue(Data([0x01]), for: char, type: .withResponse)
        enrollRequestStatus = "已请电脑弹出登记窗口…"
        record("enroll_request_sent", note: "请电脑弹出登记窗口")
    }

    private func onEnrollRequestWritten(_ error: Error?) {
        guard let error = error as NSError? else {
            enrollRequestStatus = "电脑上弹出了确认窗口：点「显示二维码」（第一次登记是「登记」），再用手机对准它"
            record("enroll_request_ok", note: "电脑弹出了确认窗口")
            return
        }
        let code = error.domain == CBATTErrorDomain ? error.code : nil
        switch code {
        case 0x81:
            enrollRequestStatus = "电脑锁着屏，看不到窗口：先解锁电脑，再点一次「扫码登记」"
        case 0x82:
            enrollRequestStatus = "电脑弹不出窗口，请在电脑上打开登记窗口"
        default:
            enrollRequestStatus = "电脑没收到请求，请在电脑上打开登记窗口"
        }
        record("enroll_request_fail", note: (code.map { String(format: "0x%02x ", $0) } ?? "") + error.localizedDescription)
    }

    private func record(_ event: String, seq: UInt32? = nil, rssi: Int? = nil, state: PhoneState? = nil,
                        latencyMs: Int? = nil, note: String = "") {
        owner.record(event, device: deviceLabel, seq: seq, rssi: rssi, state: state, latencyMs: latencyMs, note: note)
    }
}

// MARK: - CBPeripheralDelegate

extension ComputerLink: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        // 不是正在等的那一轮（比如重新连上之前发起的）就不管
        guard p === peripheral, discovery == .services else { return }
        if rediscover {
            // 发现的过程中服务又变了，这次的结果可能是旧的
            rediscover = false
            p.discoverServices([Proto.service])
            return
        }
        let found = p.services?.filter { $0.uuid == Proto.service } ?? []
        guard !found.isEmpty else {
            discovery = .idle
            onServiceMissing(p, error?.localizedDescription ?? "电脑上没有协议服务，电脑端程序可能没在运行")
            return
        }
        // 不止一个时可能有旧进程留下的（见「旧服务」），每轮都记一行
        serviceCount = found.count
        let service = found[serviceIndex % found.count]
        if found.count > 1 {
            record("service_dup", note: "协议服务有 \(found.count) 个，这次用第 \(serviceIndex % found.count + 1) 个")
        }
        if let since = serviceMissingSince {
            record("service_back", note: String(format: "电脑端服务回来了，等了 %.0f 秒", Date().timeIntervalSince(since)))
            serviceMissingSince = nil
            dropDoesNothing = false
            endBackgroundTask()
        }
        discovery = .characteristics
        p.discoverCharacteristics([Proto.heartbeat, Proto.report, Proto.info, Proto.unlockChallenge, Proto.unlockCommand,
                                   Proto.enrollAck, Proto.enrollRequest, Proto.lockCommand], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral, discovery == .characteristics else { return }
        discovery = .idle
        if rediscover {
            startDiscovery(p)
            return
        }
        let chars = service.characteristics ?? []
        guard let hb = chars.first(where: { $0.uuid == Proto.heartbeat }),
              let report = chars.first(where: { $0.uuid == Proto.report }) else {
            record("missing_char", note: error?.localizedDescription ?? "缺少 HEARTBEAT 或 REPORT")
            return
        }
        heartbeatChar = hb
        reportChar = report
        infoChar = chars.first { $0.uuid == Proto.info }
        unlockChallengeChar = chars.first { $0.uuid == Proto.unlockChallenge && $0.properties.contains(.read) }
        unlockCommandChar = chars.first { $0.uuid == Proto.unlockCommand && $0.properties.contains(.write) }
        unlockTransportReady = unlockChallengeChar != nil && unlockCommandChar != nil
        enrollAckChar = chars.first { $0.uuid == Proto.enrollAck && $0.properties.contains(.write) }
        enrollRequestChar = chars.first { $0.uuid == Proto.enrollRequest && $0.properties.contains(.write) }
        lockCommandChar = chars.first { $0.uuid == Proto.lockCommand && $0.properties.contains(.write) }
        // 电脑可以在底层连接保持时重新发布服务启用/停用解锁。仅在特征有↔无变化且
        // 与已经读过的能力不一致，或认证服务实例更换时重读 INFO；普通重复服务通知不触发。
        let unlockPresenceChanged = lastDiscoveredUnlockTransport.map { $0 != unlockTransportReady } ?? false
        let unlockServiceChanged = lastDiscoveredUnlockService.map { $0 !== service } ?? false
        if infoRead, (unlockPresenceChanged && supportsUnlock != unlockTransportReady)
            || (unlockServiceChanged && (supportsUnlock || unlockTransportReady)) {
            infoRead = false
            infoReading = nil
            invalidateUnlockReportSession()
            record("unlock_capability_refresh", note: "解锁特征发生变化，重新读取电脑能力")
        }
        lastDiscoveredUnlockTransport = unlockTransportReady
        lastDiscoveredUnlockService = service
        updateAuthenticatedReportsReady()
        p.setNotifyValue(true, for: hb)
        armWatchdog(Self.subscribeTimeout, "订阅心跳 \(Int(Self.subscribeTimeout)) 秒没完成")
        // INFO 每条连接读一次。Windows 端把读 INFO 当成手机回来了，靠它恢复暂停的心跳
        // （配对过的手机重新连上时 Windows 不报告新的订阅），所以每次连上都要读。
        // 连上后 Windows 马上发的服务变化会让特征值作废，要重新发现、重新订阅，但已经读到的 INFO 不用再读；
        // 还没读完时作废了，就在新特征值上再读一次，免得读丢了心跳恢复不了
        if let infoChar, !infoRead, infoReading !== infoChar {
            infoReading = infoChar
            p.readValue(for: infoChar)
        }
        // 服务变了重新发现完、INFO 已经读过的，登记确认在这里补发；还没读的等读完 INFO
        sendEnrollAckIfReady()
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        // 只认这一轮的心跳特征值：服务变了以后旧特征值的订阅结果才回来，不能当成订阅上了
        guard p === peripheral, c === heartbeatChar else { return }
        subscribed = c.isNotifying && error == nil
        if subscribed {
            // 旧服务上订阅也可能「成功」，那个提示等收到心跳再撤
            if linkProblem != Self.staleHint { linkProblem = nil }
            armHeartbeatWatchdog("订阅后")
        }
        notePairingProblem(error)
        // 没点配对：等用户点「重新连接」，看门狗别自己反复重连、一直弹配对请求
        if pairingHint(error) != nil { disarmWatchdog() }
        record("subscribe", note: error.map { "失败：\($0.localizedDescription)" } ?? (c.isNotifying ? "已订阅心跳" : "取消订阅"))
        if Self.isStale(error) { onStale(p, "订阅") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if c === unlockChallengeChar {
            onUnlockChallenge(c.value, error: error)
            return
        }
        if c.uuid == Proto.info {
            // 服务重新发布后的旧回包不能把新一轮的 INFO 缓存标成已读或覆盖能力。
            guard c === infoChar else { return }
            if c === infoReading { infoReading = nil }
            if error == nil { infoRead = true }  // 读失败了，下次发现完再读
        }
        if let error {
            record("read_error", note: "\(c.uuid.uuidString) \(error.localizedDescription)")
            notePairingProblem(error)
            // 只看这一轮的 INFO：旧特征值上迟到的错误不算
            if c.uuid == Proto.info, c === infoChar, Self.isStale(error) { onStale(p, "读 INFO") }
            return
        }
        guard let data = c.value else { return }
        switch c.uuid {
        case Proto.heartbeat:
            if let hb = Heartbeat(data) {
                onHeartbeat(hb)
            } else {
                record("bad_heartbeat", note: data.map { String(format: "%02x", $0) }.joined())
            }
        case Proto.info:
            onInfo(data)
        default:
            break
        }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard p === peripheral else { return }
        let value = RSSI.intValue
        onRSSI(error == nil && value != Int(Proto.rssiUnavailable) ? value : nil, error: error)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if c === unlockCommandChar {
            onUnlockWritten(error)
            return
        }
        if c.uuid == Proto.enrollAck {
            onEnrollAckWritten(error)
            return
        }
        if c.uuid == Proto.enrollRequest {
            onEnrollRequestWritten(error)
            return
        }
        if c.uuid == Proto.lockCommand {
            onLockWritten(error)
            return
        }
        if c.uuid == Proto.report { onReportWritten(c, error: error) }
        guard let error else { return }
        owner.stats.writeErrors += 1
        record("write_error", note: error.localizedDescription)
        notePairingProblem(error)
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard p === peripheral else { return }
        if supportsUnlock && invalidatedServices.contains(where: { $0.uuid == Proto.service }) {
            // 电脑可能在同一底层连接上重启。立刻丢弃旧会话 nonce，等新 INFO 后再签报告。
            infoRead = false
            infoReading = nil
            invalidateUnlockReportSession()
        }
        if discovery != .idle {
            // 正在发现：这一轮回来后再发现一次，不另起一轮。Windows 连上时马上就会发服务变化
            if !rediscover { record("service_changed", note: "电脑端的服务变了，正在发现服务，这一轮完了再发现一次") }
            requestDiscovery(p)
            return
        }
        // 我们的服务没了（程序停了；Windows 发的服务变化一般整个数据库都算）、正在等服务回来、
        // 或者上次没找全特征值时电脑的服务变了，都重新找一次。
        // 我们的服务没被作废时，手上的特征值还能用，再发现一次只会多订阅、多读一次 INFO
        guard invalidatedServices.contains(where: { $0.uuid == Proto.service })
                || serviceMissingSince != nil || heartbeatChar == nil
        else { return }
        record("service_changed", note: "电脑端的服务变了（程序可能重启了），重新发现")
        startDiscovery(p)
    }
}

// MARK: - 模拟器

#if targetEnvironment(simulator)
extension ComputerLink {
    /// 模拟器里没有蓝牙：这台假电脑每秒发一次心跳，电脑状态每 cycle 秒走一轮
    /// 未锁屏 → 已锁屏 → 请提示解锁，每轮一个新编号；offset 让几台假电脑错开
    func startSimulation(platform: String, cycle: UInt32, offset: UInt32, level: Double) {
        self.platform = platform
        simSeq = offset
        simLevel = level
        phase = .connected
        subscribed = true
        simTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.simulateHeartbeat(cycle: cycle)
        }
    }

    /// 点了锁按钮：1 秒后假装电脑回了成功，之后 20 秒保持解锁或锁屏
    func simulateAction(unlock: Bool) {
        if unlock { unlockBusy = true } else { lockBusy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.unlockBusy = false
            self.lockBusy = false
            let state = unlock ? ComputerState.unlocked : ComputerState.locked
            self.simHold = (state, Date().addingTimeInterval(20))
            self.showFeedback(unlock ? "电脑已确认解锁。" : "电脑已锁屏。", failed: false)
            self.onComputerState(Heartbeat(seq: self.simSeq, computerState: state, promptID: self.promptID, nextWithin: 1))
        }
    }

    private func simulateHeartbeat(cycle: UInt32) {
        simSeq &+= 1
        // 一轮里前 3/8 未锁屏、接着 1/4 已锁屏、最后 3/8 请提示解锁（40 秒一轮就是 15、10、15 秒）
        let phase = simSeq % cycle
        var state = phase < cycle * 3 / 8 ? ComputerState.unlocked
            : phase < cycle * 5 / 8 ? ComputerState.locked : ComputerState.promptUnlock
        if let hold = simHold {
            if Date() < hold.until { state = hold.state } else { simHold = nil }
        }
        onHeartbeat(Heartbeat(seq: simSeq, computerState: state, promptID: UInt16(truncatingIfNeeded: simSeq / cycle + 1),
                              nextWithin: 1))
        simLevel = min(-45, max(-90, simLevel + Double.random(in: -2.5...2.5)))
        let value = Int(simLevel.rounded())
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 20...60))) { [weak self] in
            self?.onRSSI(value, error: nil)
        }
    }
}
#endif
