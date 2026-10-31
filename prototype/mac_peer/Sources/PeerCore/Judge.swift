import Foundation

/// 判断参数，和 win_peer.py 的命令行参数同名、同默认值
public struct JudgeConfig {
    /// false：只记录本来会怎么做（would_lock / would_prompt），不真的锁屏（--no-lock）
    public var lock = true
    /// 自己锁屏 2 秒后关显示器（--keep-display 关掉）
    public var displayOff = true
    /// 请手机提示解锁时点亮屏幕，人坐下就能看到锁屏界面（--no-wake 关掉）
    public var wakeOnPrompt = true
    /// 多少秒内有键盘鼠标操作就算在电脑前（--active）
    public var active = 30.0
    /// 多少秒没有操作才可能判定离开（--idle-lock）
    public var idleLock = 60.0
    /// 信号中位数低于它算弱（--far-th）
    public var farTh = -80.0
    /// 信号弱持续多少秒算离开（--far-for）
    public var farFor = 10.0
    /// 手机失联多少秒算离开（--lost-for）
    public var lostFor = 10.0
    /// 判定离开后，信号中位数回到它以上、并持续 approachFor 秒，就提示解锁（--approach-th）
    public var approachTh = -72.0
    /// 见 approachTh（--approach-for）
    public var approachFor = 3.0
    /// 还要比走远时的信号（Judge.reference）强这么多 dB 才提示、才退出休眠（--approach-gain）
    public var approachGain = 10.0
    /// 「走远时的信号」看最近多少秒的报告（--ref-window）；最近 30 秒不算，免得把正在走回来的那几秒算进去
    public var refWindow = 900.0
    /// 电脑端启动后多少秒内不算手机失联（--startup-grace）
    public var startupGrace = 30.0
    /// 提示解锁以后，手机持续走远（失联或信号弱）多少秒才撤销提示；锁屏期间也要走远这么久才算走远过（--cancel-after）
    public var cancelAfter = 60.0
    /// 心跳间隔（--interval）
    public var interval = 1.0
    /// 多少秒没收到报告算手机失联、停发心跳（--pause-after）；心跳慢下来时跟着放宽，见 Judge.reportTimeout
    public var pauseAfter = 3.0
    /// 没人在用电脑、信号中位数低于它时，心跳放慢到 slowInterval（--slow-th）
    public var slowTh = -75.0
    /// 见 slowTh（--slow-interval）
    public var slowInterval = 3.0
    /// 锁着、并且多少秒没碰键盘鼠标就休眠，不看信号（--dormant-after）
    public var dormantAfter = 1800.0
    /// 休眠时心跳间隔（--dormant-interval）
    public var dormantInterval = 30.0
    /// 电脑端被系统睡眠冻住多少秒、醒来时锁着（显示器亮了），就当作手机走远过、回来请提示（--freeze-away）
    public var freezeAway = 60.0

    public init() {}
}

/// 什么时候发下一次心跳（和 win_peer.py 的 HeartbeatSchedule 一样）。每次心跳都宣布「下一次最晚几秒后到」，所以：
/// - 变快（比如休眠时手机信号变强）：马上按新的间隔算，到点就发
/// - 变慢：已经宣布过的不能失信，按上一次宣布的间隔发下一次，这一次再宣布新的间隔
public struct HeartbeatSchedule {
    public private(set) var announced: Double
    public private(set) var lastSent: Double?

    public init(interval: Double) {
        announced = interval
    }

    public func due(_ now: Double, interval: Double) -> Bool {
        guard let lastSent else { return true }
        return now - lastSent >= min(interval, announced)
    }

    public mutating func sent(_ now: Double, interval: Double) {
        lastSent = now
        announced = interval
    }
}

/// 判断要用的系统接口，测试时换成假的
public protocol HostSystem: AnyObject {
    /// 距离上次键盘鼠标操作过了多少秒，取不到时 nil
    func idleSeconds() -> Double?
    func screenLocked() -> Bool
    /// 锁屏。失败时 note 写原因
    func lockScreen() -> (ok: Bool, note: String)
    /// 关显示器（不睡眠）。失败时 note 写原因
    func displayOff() -> (ok: Bool, note: String)
    /// 点亮显示器，和动一下鼠标一样。失败时 note 写原因
    func displayOn() -> (ok: Bool, note: String)
    /// 显示器睡没睡：true 睡着（关了屏、Power Nap 的维护唤醒），false 亮着，nil 不知道。冻住后醒来时用
    func displayAsleep() -> Bool?
}

/// 判断要的连接状态，由 Peer 每次提供
public struct LinkSnapshot {
    public var hasClients: Bool
    /// 最后一次收到报告的时间（Unix 秒）
    public var lastReportWall: Double?
    /// 最近的报告（时间、RSSI）：中位数用最后 5 次，「走远时的信号」用最近 refWindow 秒的，所以要给够
    public var recent: [(wall: Double, rssi: Int)]
    /// App 在报告里写的协议版本，没写就是 1；≥ 2 才会进休眠
    public var appProto: Int

    public init(hasClients: Bool, lastReportWall: Double?, recent: [(wall: Double, rssi: Int)], appProto: Int = 1) {
        self.hasClients = hasClients
        self.lastReportWall = lastReportWall
        self.recent = recent
        self.appProto = appProto
    }
}

/// 电脑端判断人在不在，据此锁屏、请手机提示解锁。和 win_peer.py 的 Judge 一致，
/// 规则见 docs/protocol.md「电脑怎么判断人在不在、锁屏、请手机提示解锁」：
/// - 在电脑前：active 秒内有键盘鼠标操作，不管信号多少
/// - 离开：idleLock 秒没有操作，并且手机失联 lostFor 秒、或信号中位数低于 farTh 持续 farFor 秒
///   → 锁屏（lock）；不锁屏模式只记 would_lock。这台电脑从没收到过手机报告时（phoneKnown 也没设），失联不算离开
/// - 手机走后只锁一次：锁过以后手机还没回来就被解开了（多半是远程解的），手机回来以前不再自动锁（holdLock）
/// - 锁屏期间手机持续走远 cancelAfter 秒（armed），之后信号连续 approachFor 秒在 approachTh 以上、并且比走远时的信号
///   （reference）强 approachGain → 请手机提示解锁
///   （prompt，心跳里电脑状态 3）。用户自己锁屏、人还坐着时手机一直在附近，不会 armed，所以不提示。
///   提示以后手机又持续走远 cancelAfter 秒才撤销（prompt_cancel）
/// - 电脑端被系统睡眠冻住超过 freezeAway 秒、醒来时锁着、显示器亮了：冻住期间看不到手机走没走，
///   当作手机走远过（armed），手机在旁边就请提示（freeze_away）
/// - 解锁（不锁屏模式是又有了键盘鼠标操作）→ 记 back，写提示后多久解锁
/// - 心跳分三档（heartbeatInterval，见 docs/protocol.md「心跳快慢和休眠」）：每秒一次、慢（3 秒）、休眠（30 秒）
public final class Judge {
    public enum State: String {
        case present, away, idle

        var name: String {
            switch self {
            case .present: "在电脑前"
            case .away: "离开"
            case .idle: "没在操作"
            }
        }
    }

    public let config: JudgeConfig
    private let system: HostSystem
    private let started: Double
    /// 记日志：事件名、rssi 列、note
    public var log: (String, String, String) -> Void = { _, _, _ in }
    /// 打印到终端
    public var say: (String) -> Void = { _ in }

    public private(set) var state: State?
    private var weakSince: Double?
    private var lostSince: Double?
    /// 判定离开（锁屏）的时间
    public private(set) var awayAt: Double?
    /// 请手机提示解锁的时间
    private var promptAt: Double?
    /// 心跳里正在发电脑状态 3
    public private(set) var prompting = false
    /// 锁屏期间手机走远过，回来时要提示
    private var armed = false
    /// 信号从什么时候起一直在 approachTh 以上、并且比走远时强 approachGain
    private var nearSince: Double?
    /// 手机从什么时候起走远的（armed 的那一段）：「走远时的信号」只看这以后的报告，不把人还坐在电脑前的信号算进去
    private var refStart: Double?
    /// 最近一次判断时「走远时的信号」，nil 是最近一段没有报告（手机刚连回来）
    public private(set) var lastRef: Double?
    /// 最近一次判断时的空闲秒数
    private var lastIdle: Double?
    /// 最近一次判断时的信号中位数，心跳快慢用
    public private(set) var lastMed: Double?
    /// 最新一条报告的信号（还没过期的）
    private var lastRSSI: Int?
    /// App 报的协议版本
    private var appProto = 1
    /// 最近一次心跳宣布的间隔，Peer 发心跳时设。失联阈值和中位数窗口跟着放宽
    public var currentInterval: Double
    /// 判定离开后确实看到锁上了（锁屏是异步生效的）
    private var seenLocked = false
    /// 判定离开后，到这个时间关显示器（自己锁的等 2 秒，本来就锁着的马上关）
    private var displayOffAt: Double?
    /// 请提示时点亮了屏幕，撤销提示时要关回去
    private var displayWoken = false
    public private(set) var promptID: Int
    /// 真实的锁屏状态
    public private(set) var locked: Bool?
    /// 这台电脑以前收到过手机的报告（重启前的日志里有，或者登记过解锁的手机），Peer 启动时设。
    /// 这样这次启动以来还没收到报告时，失联也算离开：不然电脑端在手机不在时重启以后，
    /// 按原来「这次启动以来没收到过报告就不算」，就再也不锁了
    public var phoneKnown = false
    /// 手机走后已经锁过一次、手机还没回来就被解开了（多半是远程解的）：手机回来以前不再自动锁。
    /// 远程操作 Mac 时，操作停一下不应该就锁，不然每次都得远程输密码
    public private(set) var holdLock = false
    /// 上次判断的时间：隔了很久说明电脑端被系统睡眠冻住了
    private var lastUpdate: Double?
    /// 冻住后醒来时锁着、等显示器亮了再当作手机走远过：冻住是从什么时候开始的
    private var frozenSince: Double?

    public init(config: JudgeConfig, system: HostSystem, started: Double, promptID: Int? = nil) {
        self.config = config
        self.system = system
        self.started = started
        // 每次启动换一个起点，重启后不和之前的编号撞上
        self.promptID = promptID ?? Int(started) % 60000 + 1
        currentInterval = config.interval
    }

    /// 最近 5 次报告的信号中位数（只算最近 window 秒的）
    public static func median(_ recent: [(wall: Double, rssi: Int)], now: Double, window: Double = 10) -> Double? {
        let values = recent.suffix(5).filter { $0.rssi != Proto.rssiUnavailable && $0.wall > now - window }.map(\.rssi).sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count % 2 == 1 ? Double(values[mid]) : Double(values[mid - 1] + values[mid]) / 2
    }

    /// 「走远时的信号」：最近 window 秒（不含最近 lag 秒）、start 以后的报告里，信号强的那一头（90% 分位）。
    /// 少于 3 条时 nil（手机刚连回来，或者刚走开）。
    /// 手机放在别的房间时，信号可能在 -70 到 -90 之间来回（被身体、被子挡），中位数会在 -82 停几分钟再回到 -72：
    /// 拿中位数当参考，回到 -72 就正好强了 10 dB，照样半夜提示；拿强的那一头（这时最强也就 -71）才分得开
    public static func reference(_ recent: [(wall: Double, rssi: Int)], now: Double, start: Double?,
                                 window: Double, lag: Double = 30) -> Double? {
        let from = max(now - lag - window, start ?? -.infinity)
        let values = recent.filter { $0.rssi != Proto.rssiUnavailable && $0.wall >= from && $0.wall <= now - lag }
            .map(\.rssi).sorted()
        guard values.count >= 3 else { return nil }
        return Double(values[min(values.count - 1, values.count * 9 / 10)])
    }

    /// 多久没报告算失联：平时 pauseAfter（3 秒）；心跳慢下来时报告本来就隔得久，跟着放宽（休眠时 32 秒）
    public var reportTimeout: Double {
        config.pauseAfter + max(0, currentInterval - 1)
    }

    /// 算信号中位数的时间窗口：平时 10 秒，心跳慢下来时跟着放宽（休眠时 62 秒）
    private var medianWindow: Double {
        max(10, currentInterval * 2 + 2)
    }

    /// 真锁屏时看系统；不锁屏模式判定离开就算本来已经锁了
    public var screenLocked: Bool {
        config.lock ? locked == true : awayAt != nil
    }

    /// 写进心跳的电脑状态：1 未锁屏，2 已锁屏，3 已锁屏且请手机提示解锁
    public var hostState: UInt8 {
        guard screenLocked else { return 1 }
        return prompting ? 3 : 2
    }

    /// 每秒调用一次
    public func update(link: LinkSnapshot, now: Double) {
        let a = config
        let gap = lastUpdate.map { now - $0 } ?? 0
        lastUpdate = now
        let idle = system.idleSeconds()
        let med = Self.median(link.recent, now: now, window: medianWindow)
        appProto = link.appProto
        // 电脑端刚启动时手机还没连回来，不算失联
        let silent = !link.hasClients || link.lastReportWall.map { now - $0 > reportTimeout } ?? true
        let lost = silent && now - started > a.startupGrace
        lostSince = lost ? (lostSince ?? now) : nil
        let weak = !lost && med.map { $0 < a.farTh } == true
        weakSince = weak ? (weakSince ?? now) : nil

        lastIdle = idle
        let present = idle.map { $0 < a.active } == true
        var away = false
        if let idle, idle >= a.idleLock {
            // 手机失联算离开的前提是这次启动以来收到过它的报告：分不清"手机走了"和"手机根本没连这台电脑"
            // （比如 App 还没添加它），宁可不锁，不然会把坐着、只是一会儿没碰电脑的人锁住
            // phoneKnown：以前收到过报告（重启前），见 phoneKnown
            let lostAway = lostSince.map { now - $0 >= a.lostFor } == true && (link.lastReportWall != nil || phoneKnown)
            away = lostAway || (weakSince.map { now - $0 >= a.farFor } == true)
        }
        let state: State = present ? .present : away ? .away : .idle
        let enteringAway = state == .away && self.state != .away
        if state != self.state {
            let idleS = idle.map(fmt0) ?? "?"
            let why = "空闲 \(idleS)s" + (med.map { "，信号 \(fmt0($0))" } ?? "") + (lost ? "，手机失联" : "")
            say("电脑判断 → \(state.name)（\(why)）")
            log("judge", med.map(fmt0) ?? "", "\(state.rawValue) idle=\(idleS)s" + (lost ? " lost" : ""))
            self.state = state
        }

        let locked = system.screenLocked()
        if locked != self.locked {
            if self.locked != nil { say(locked ? "Mac 已锁屏" : "Mac 已解锁") }
            log(locked ? "locked" : "unlocked", "", "")
            self.locked = locked
        }
        if locked && awayAt != nil { seenLocked = true }

        // 电脑端被冻住过（系统睡眠：MacBook 合盖、手动睡眠），醒来时锁着：冻住期间看不到手机走没走，
        // 当作手机走远过（armed），手机在旁边就请提示。和 win_peer.py 一样：走开时合了盖，冻住前还没判定离开，
        // 醒来时手机马上就连回来了，可电脑端没看到手机走过，就会一直不提示，只能手动解锁。
        // 要等显示器亮了（开盖、按键）才算：Power Nap 的维护唤醒显示器不亮、盖子可能合着，这时不能解
        if gap >= a.freezeAway && a.lock && locked && !(armed || prompting) {
            if frozenSince == nil && system.displayAsleep() == true {
                log("freeze_wait", "", "电脑端 \(fmt0(gap))s 没转（睡眠冻住了），醒来锁着、显示器没亮，等亮了再当作离开过")
            }
            frozenSince = frozenSince ?? now - gap
        }
        if let since = frozenSince {
            if !locked || armed || prompting {
                frozenSince = nil
            } else if system.displayAsleep() != true {
                let clock = DateFormatter()
                clock.dateFormat = "HH:mm:ss"
                let note = "电脑端从 \(clock.string(from: Date(timeIntervalSince1970: since))) 起被睡眠冻住，"
                    + "醒来锁着、显示器亮了，当作手机走远过，手机在旁边就请提示"
                say(note)
                log("freeze_away", "", note)
                armed = true
                refStart = since  // 「走远时的信号」只看冻住以后的报告，冻住前人还坐着
                frozenSince = nil
            }
        }

        // 判定离开 → 锁屏；手机走后已经锁过一次、被解开了就不再锁（holdLock）
        if state == .away && awayAt == nil && holdLock {
            if enteringAway {
                let why = "空闲 \(idle.map(fmt0) ?? "?")s，" + (lost ? "手机失联" : "信号 \(med.map(fmt0) ?? "?")")
                say("判定离开，但手机走后已经锁过一次、被解开了，不再锁")
                log("lock_skip", "", why + "；手机走后已经锁过一次、被解开了，手机回来以前不再自动锁")
            }
        } else if state == .away && awayAt == nil {
            // 判定离开只要手机失联或信号弱 10 秒，还不算「走远过」（armed）：要像下面那样持续走远 cancelAfter 秒。
            // 原来这里直接 armed，判定离开后头二十来秒「走远时的信号」还没有报告（reference 为 nil），「强 10 dB」被跳过，
            // 信号回到 -72 就请提示：信号只是跌了一下、手机还在屋里，电脑就会自动解锁，可没人在用
            awayAt = now
            let why = "空闲 \(idle.map(fmt0) ?? "?")s，" + (lost ? "手机失联" : "信号 \(med.map(fmt0) ?? "?")")
            if !a.lock {
                say("⇒ 本来会锁屏")
                log("would_lock", "", why)
            } else if locked {
                say("判定离开（Mac 本来就锁着）")
                log("lock", "", why + "，本来就锁着")
                if a.displayOff {
                    displayOffAt = now  // 锁屏界面早就出来了，马上关
                }
            } else {
                let r = system.lockScreen()
                say(r.ok ? "⇒ 已锁屏：你离开了" : "⇒ 锁屏失败")
                log("lock", "", why + (r.ok ? "" : "，\(r.note)"))
                if r.ok && a.displayOff {
                    displayOffAt = now + 2  // 等锁屏界面出来再关，免得被锁屏动画重新点亮
                }
            }
        }

        // 锁屏不会关屏，屏幕要亮到系统设定的关屏时间。判定离开以后关掉，不管是谁锁的：用户自己锁的、屏保锁的
        // 原来不动，按系统自己的设置，屏保锁的会一直放着屏保（和 Windows 一样）
        if let at = displayOffAt, now >= at {
            displayOffAt = nil
            if locked {
                let r = system.displayOff()
                say(r.ok ? "⇒ 已关屏" : "⇒ 关屏失败")
                log("display_off", "", r.ok ? "" : r.note)
            }
        }

        // 锁屏期间：手机走远过、又回来了 → 请手机提示解锁。
        // 信号要连续 approachFor 秒都在 approachTh 以上：Windows 两天的日志里 65 次提示大多是在 -79 到 -82
        // 弹的（手机在别的房间、蓝牙范围边上，信号一跳就算回来），夜里也弹
        lastMed = med
        lastRSSI = link.recent.last.flatMap { $0.rssi != Proto.rssiUnavailable && $0.wall > now - reportTimeout ? $0.rssi : nil }
        // 还要比走远时明显变强：手机放在别的房间时信号也会到 -72，只看阈值会整夜反复提示
        let ref = Self.reference(link.recent, now: now, start: refStart, window: a.refWindow)
        lastRef = ref
        if !lost, let med, med >= a.approachTh, ref.map({ med >= $0 + a.approachGain }) ?? true {
            nearSince = nearSince ?? now
        } else {
            nearSince = nil
        }
        let phoneNear = nearSince.map { now - $0 >= a.approachFor } == true
        if holdLock && phoneNear, let med {
            holdLock = false
            say("手机回来了，恢复自动锁屏")
            log("lock_resume", fmt0(med), "手机回来了，恢复自动锁屏")
        }
        // 手机持续走远（失联或信号弱）cancelAfter 秒才算"走远过"：信号在阈值附近来回跳、偶尔几秒没报告都不算，
        // 不然会反复撤销、重弹通知（Windows 实测锁屏 3 小时里撤了又弹二十多次）
        let goneFor = max(lostSince.map { now - $0 } ?? 0, weakSince.map { now - $0 } ?? 0)
        let phoneGone = goneFor >= a.cancelAfter
        if screenLocked {
            if phoneGone {
                armed = true  // 也包括用户自己锁屏后带着手机走开
                refStart = refStart ?? goneStart(now)
                if prompting {
                    prompting = false  // 提示过以后人又走远了，撤销，等下次回来再提示
                    promptAt = nil     // 不清掉的话，之后解锁会记成「提示后几万秒解锁」
                    // 「走远时的信号」从这次走开算起：不然上次回来时的强信号还在参考里，再回来就不提示了
                    refStart = goneStart(now)
                    say("手机又走远了，撤销解锁提示")
                    log("prompt_cancel", "", "")
                    if displayWoken {
                        displayWoken = false
                        if a.displayOff && locked {
                            let r = system.displayOff()
                            log("display_off", "", r.ok ? "手机又走远了" : r.note)
                        }
                    }
                }
            } else if armed && phoneNear && !prompting, let med {
                prompting = true
                armed = false
                promptAt = now
                promptID = promptID % 65535 + 1
                let note = "id=\(promptID)" + (awayAt.map { "，离开 \(fmt0(now - $0))s 后" } ?? "")
                    + (ref.map { "，比走远时（\(fmt0($0))）强 \(fmt0(med - $0)) dB" } ?? "，之前一段没有报告（手机刚连回来）")
                say("⇒ 手机回来了（信号 \(fmt0(med))），请手机提示解锁")
                log(a.lock ? "prompt" : "would_prompt", fmt0(med), note)
                // 自己关了屏的话人回来时屏幕是黑的，点亮它，坐下就能看到锁屏界面
                if a.lock && locked && a.wakeOnPrompt {
                    let r = system.displayOn()
                    say(r.ok ? "⇒ 已点亮屏幕" : "⇒ 点亮屏幕失败")
                    log("display_on", "", r.ok ? "" : r.note)
                    displayWoken = r.ok
                }
            }
        }

        // 回来了：真锁屏时看系统解锁；不锁屏模式或锁屏失败时看键盘鼠标
        let back: Bool
        if a.lock {
            back = !locked && (seenLocked || (awayAt != nil && present) || (awayAt == nil && promptAt != nil))
        } else {
            back = awayAt != nil && present
        }
        if back {
            let note: String
            if let promptAt {
                note = "提示后 \(fmt0(now - promptAt))s " + (a.lock ? "解锁" : "动了键盘鼠标")
            } else {
                note = "没提示就" + (a.lock ? "解锁了" : "回来了")
            }
            say("⇒ 回来了：\(note)")
            log("back", med.map(fmt0) ?? "", (awayAt.map { "离开 \(fmt0(now - $0))s，" } ?? "") + note)
            // 判定离开锁的屏、手机还没回来（失联或信号弱）就被解开了：多半是人在外面远程解的，手机回来以前不再自动锁
            if awayAt != nil && (lost || weak) && !holdLock {
                holdLock = true
                say("手机还没回来就被解开了（可能是远程），手机回来以前不再自动锁")
                log("lock_hold", "", "手机还没回来就被解开了（多半是远程解的），手机回来以前不再自动锁")
            }
            awayAt = nil
            promptAt = nil
            prompting = false
            armed = false
            refStart = nil
            seenLocked = false
            displayWoken = false
        } else if a.lock && !locked && awayAt == nil {
            // 用户自己锁屏又自己解锁，中间没提示过
            prompting = false
            armed = false
            refStart = nil
        }
    }

    /// 心跳分三档（docs/protocol.md「心跳快慢和休眠」，和 win_peer.py 的 heartbeat_interval 一样）：
    /// - 每秒一次（interval）：有人在用电脑，或者手机信号不弱
    /// - 慢（slowInterval，3 秒）：没人用电脑、信号中位数 < slowTh（-75）。Windows 两天里卡死 69 次，大多在夜里
    ///   手机在远处、信号 -80 到 -95 时，发得越勤越容易碰上
    /// - 休眠（dormantInterval，30 秒）：锁着、dormantAfter（30 分钟）没碰键盘鼠标，**不看信号**。
    ///   每发一次心跳就把 App 叫醒一次，一晚上上万次，耗手机电。原来要信号 < -80 持续 10 分钟，
    ///   可手机放在别的房间时信号一直在 -69 到 -76（和揣兜里坐在电脑前差不多），根本进不去
    /// 每次心跳都写明下一次最晚几秒后到，App 的看门狗跟着放宽。最新一条报告比走远时明显变强（≥ 参考 + approachGain，
    /// 包括手机亮屏时 App 主动报的），或者前一段没有报告（手机刚连回来），就回到每秒一次
    public func heartbeatInterval(now: Double) -> Double {
        let a = config
        if state == .present { return a.interval }
        // 休眠要 App 认识心跳里「下一次最晚几秒」（报告里写了协议版本 ≥ 2）：旧 App 的看门狗固定 5 秒，
        // 30 秒一次心跳会让它以为断了、每 5 秒重连一次，反而更耗电
        if appProto >= 2, screenLocked, let idle = lastIdle, idle >= a.dormantAfter, let ref = lastRef,
           !(lastRSSI.map { Double($0) >= ref + a.approachGain } ?? false) {
            return a.dormantInterval
        }
        // 进入慢档看中位数；退出只要最新一条够强
        if lastMed.map({ $0 >= a.slowTh }) ?? true || lastRSSI.map({ Double($0) >= a.slowTh }) == true {
            return a.interval
        }
        return a.slowInterval
    }

    /// 启动时接上前一个进程的判断（和 win_peer.py 的 Judge.restore 一样）：前一个日志里最后一次锁屏之后还没有 back，
    /// 就还算离开，接着用原来的提示编号（手机不会重弹通知）、从判定离开的时间算「走远时的信号」。
    /// 最近的报告由 Peer 读回来、放进 LinkSnapshot.recent：不然参考是空的，提示只看 -72，夜里一重启就可能误提示。
    /// stillLocked：真锁屏模式下现在锁不锁着。重启期间用户解锁了就不接：接了以后 awayAt 有值，人再走开也不会再锁屏
    /// 返回记进日志的 note，没接上返回 nil
    @discardableResult
    public func restore(events: [(wall: Double, event: String, note: String)], now: Double, stillLocked: Bool) -> String? {
        var away: Double?
        var prompt: Double?
        var isPrompting = false
        var pid: Int?
        for e in events {
            switch e.event {
            case "lock", "would_lock":
                away = e.wall
                prompt = nil
                isPrompting = false
            case "prompt", "would_prompt":
                prompt = e.wall
                isPrompting = true
                if let r = e.note.range(of: #"id=(\d+)"#, options: .regularExpression) {
                    pid = Int(e.note[r].dropFirst(3)) ?? pid
                }
            case "prompt_cancel":
                prompt = nil
                isPrompting = false
            case "back":
                away = nil
                prompt = nil
                isPrompting = false
            default:
                break
            }
        }
        guard away != nil || isPrompting, !config.lock || stillLocked else { return nil }
        awayAt = away
        promptAt = prompt
        prompting = isPrompting
        armed = !isPrompting
        refStart = away
        if let pid { promptID = pid }
        let note = (away.map { "\(fmt0(now - $0))s 前判定离开" } ?? "用户自己锁的屏") + (isPrompting ? "，正在提示解锁 id=\(promptID)" : "")
        say("接上前一个进程的判断：\(note)")
        log("judge_restore", "", note)
        return note
    }

    /// 启动时接上前一个进程的「不再自动锁」（holdLock）：最后一次 lock_hold 之后没有 lock_resume、lock 就还接着不锁。
    /// 自动解锁启用时也接（restore 不接旧的信号和提示，这个只会让电脑少锁，不会多解锁）。返回记进日志的 note，没接上返回 nil
    @discardableResult
    public func restoreHold(events: [(wall: Double, event: String, note: String)], now: Double) -> String? {
        var hold: Double?
        for e in events {
            switch e.event {
            case "lock_hold": hold = e.wall
            case "lock_resume", "lock", "would_lock": hold = nil
            default: break
            }
        }
        guard let hold else { return nil }
        holdLock = true
        let note = "\(fmt0(now - hold))s 前手机还没回来就被解开了，接着不自动锁，等手机回来"
        say("接上前一个进程：\(note)")
        log("lock_hold", "", "接上前一个进程：" + note)
        return note
    }

    /// 手机从什么时候起算走远的：失联、信号弱里更早开始的那个
    private func goneStart(_ now: Double) -> Double {
        [lostSince, weakSince].compactMap { $0 }.min() ?? now
    }

    public func summary() -> String {
        var text = ""
        if let idle = system.idleSeconds() {
            text = "电脑判断 \(state?.name ?? "-")（空闲 \(fmt0(idle))s）"
        }
        if currentInterval >= config.dormantInterval {
            text += "，休眠（心跳 \(fmt0(currentInterval)) 秒一次）"
        }
        if prompting {
            text += "，正在请手机提示解锁"
        } else if screenLocked {
            text += "，锁屏中"
        }
        return text
    }
}
