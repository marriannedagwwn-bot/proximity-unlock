import XCTest
@testable import PeerCore

/// 假的系统：时间、键盘鼠标、锁屏都由测试控制
final class FakeSystem: HostSystem {
    var now = 1_000_000.0
    var lastInput = 1_000_000.0
    var locked = false
    var lockCalls = 0
    /// 每次关屏的时间
    var displayOffs: [Double] = []

    func idleSeconds() -> Double? { now - lastInput }
    func screenLocked() -> Bool { locked }
    func lockScreen() -> (ok: Bool, note: String) {
        lockCalls += 1
        locked = true
        return (true, "")
    }
    func displayOff() -> (ok: Bool, note: String) {
        displayOffs.append(now)
        return (true, "")
    }
    /// 每次点亮屏幕的时间
    var displayOns: [Double] = []
    func displayOn() -> (ok: Bool, note: String) {
        displayOns.append(now)
        return (true, "")
    }
}

/// 一秒一步地模拟：手机每秒报一次信号（nil 表示失联），记下判断记的日志
final class Sim {
    let sys = FakeSystem()
    let judge: Judge
    var events: [(t: Double, event: String, rssi: String, note: String)] = []
    var recent: [(wall: Double, rssi: Int)] = []
    var lastReport: Double?
    let t0: Double

    var appProto = 1
    var schedule: HeartbeatSchedule
    /// 按心跳节奏跑时每次心跳宣布的间隔
    var intervals: [Double] = []

    init(lock: Bool = true, displayOff: Bool = true, wake: Bool = true, configure: (inout JudgeConfig) -> Void = { _ in }) {
        var c = JudgeConfig()
        c.lock = lock
        c.displayOff = displayOff
        c.wakeOnPrompt = wake
        configure(&c)
        t0 = sys.now
        schedule = HeartbeatSchedule(interval: c.interval)
        judge = Judge(config: c, system: sys, started: sys.now, promptID: 100)
        judge.log = { [unowned self] e, r, n in self.events.append((self.sys.now - self.t0, e, r, n)) }
    }

    private func update() {
        // 和 main.swift 一样给最近 --ref-window + 60 秒的报告（「走远时的信号」要用）
        let since = sys.now - judge.config.refWindow - 60
        judge.update(link: LinkSnapshot(hasClients: true, lastReportWall: lastReport,
                                        recent: Array(recent.drop { $0.wall < since }.suffix(2000)), appProto: appProto),
                     now: sys.now)
    }

    /// 走 seconds 秒，这期间手机信号是 rssi（nil：没有报告），active 时一直在动键盘鼠标
    func run(_ seconds: Int, rssi: Int?, active: Bool = false) {
        for _ in 0..<seconds {
            sys.now += 1
            if active { sys.lastInput = sys.now }
            if let rssi {
                recent.append((sys.now, rssi))
                lastReport = sys.now
            }
            update()
        }
    }

    /// 和 main.swift 一样按三档间隔发心跳，手机每收到一次心跳就回一次报告（信号 rssi，nil：手机不在、没有报告）
    func runHeartbeats(_ seconds: Int, rssi: Int?, active: Bool = false) {
        for _ in 0..<seconds {
            sys.now += 1
            if active { sys.lastInput = sys.now }
            let interval = judge.heartbeatInterval(now: sys.now)
            if schedule.due(sys.now, interval: interval) {
                schedule.sent(sys.now, interval: interval)
                judge.currentInterval = interval
                intervals.append(interval)
                if let rssi {
                    recent.append((sys.now, rssi))
                    lastReport = sys.now
                }
            }
            update()
        }
    }

    /// 手机主动报一次（亮屏时 App 读一次 RSSI 写的 REPORT），不等心跳
    func wakeReport(_ rssi: Int) {
        recent.append((sys.now, rssi))
        lastReport = sys.now
    }

    func names(_ wanted: Set<String>) -> [String] {
        events.map(\.event).filter(wanted.contains)
    }

    func first(_ event: String) -> (t: Double, event: String, rssi: String, note: String)? {
        events.first { $0.event == event }
    }

    static let main: Set<String> = ["lock", "would_lock", "prompt", "would_prompt", "prompt_cancel", "back"]
}

final class JudgeTests: XCTestCase {
    /// 坐着 3 分钟不碰键盘、信号 -75（揣兜里）：不能判成离开
    func testSittingStillIsNotAway() {
        let s = Sim()
        s.run(40, rssi: -75, active: true)
        s.run(180, rssi: -75)
        XCTAssertEqual(s.names(Sim.main), [])
        XCTAssertEqual(s.judge.state, .idle)
        XCTAssertEqual(s.sys.lockCalls, 0)
        XCTAssertEqual(s.judge.hostState, 1)
    }

    /// 离开（信号变弱）→ 锁屏 → 回来提示解锁 → 解锁 → back
    func testLeaveLockReturnPromptUnlock() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(30, rssi: -60)          // 没在操作
        s.run(60, rssi: -85)          // 走远
        XCTAssertEqual(s.sys.lockCalls, 1)
        XCTAssertEqual(s.judge.hostState, 2)
        let lock = s.first("lock")!
        // 空闲满 60 秒才锁（第 40 秒最后一次操作，信号弱早已超过 10 秒）
        XCTAssertEqual(lock.t, 100)
        XCTAssertTrue(lock.note.contains("信号 -85"), lock.note)

        s.run(6, rssi: -60)           // 回来：中位数第 3 秒翻上来，再连续 3 秒
        let prompt = s.first("prompt")!
        XCTAssertEqual(prompt.note.prefix(6), "id=101")
        XCTAssertEqual(s.judge.hostState, 3)
        XCTAssertEqual(s.judge.promptID, 101)

        s.sys.locked = false          // 用户解锁
        s.sys.lastInput = s.sys.now
        s.run(1, rssi: -60)
        XCTAssertEqual(s.names(Sim.main), ["lock", "prompt", "back"])
        XCTAssertTrue(s.first("back")!.note.contains("提示后"), s.first("back")!.note)
        XCTAssertEqual(s.judge.hostState, 1)
    }

    /// 手机断开（没有报告）也算离开；回来重新连上马上提示
    func testLostPhone() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(70, rssi: nil)
        XCTAssertEqual(s.sys.lockCalls, 1)
        XCTAssertTrue(s.first("lock")!.note.contains("手机失联"), s.first("lock")!.note)
        s.run(3, rssi: -55)
        XCTAssertNil(s.first("prompt"), "要连续 3 秒")
        s.run(1, rssi: -55)
        XCTAssertNotNil(s.first("prompt"))
    }

    /// 用户自己锁屏、人还坐着（手机一直在附近）：不提示
    func testManualLockWhileSittingNoPrompt() {
        let s = Sim()
        s.run(40, rssi: -65, active: true)
        s.sys.locked = true
        s.run(120, rssi: -65)
        XCTAssertEqual(s.names(Sim.main), [])
        XCTAssertEqual(s.judge.hostState, 2)
        s.sys.locked = false
        s.sys.lastInput = s.sys.now
        s.run(2, rssi: -65)
        XCTAssertEqual(s.names(Sim.main), [])
        XCTAssertEqual(s.judge.hostState, 1)
    }

    /// 用户自己锁屏后带着手机走开再回来：照样提示
    func testManualLockThenWalkAwayAndBack() {
        // 空闲很久才判离开：只看「锁屏期间持续走远 60 秒就 armed」这一条
        let s = Sim { $0.idleLock = 600 }
        s.run(40, rssi: -65, active: true)
        s.sys.locked = true
        s.run(5, rssi: -65)
        s.run(70, rssi: -88)   // 走远，没判离开，但锁屏期间持续走远 60 秒就 armed
        s.run(8, rssi: -62)
        XCTAssertEqual(s.names(Sim.main), ["prompt"])
        XCTAssertFalse(s.first("prompt")!.note.contains("离开"), "没判过离开，note 不写离开多久")
        s.sys.locked = false
        s.run(1, rssi: -62, active: true)
        XCTAssertEqual(s.names(Sim.main), ["prompt", "back"])
    }

    /// 提示后又走远 → 撤销；再回来用新编号提示
    func testPromptCancelAndReprompt() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)
        s.run(8, rssi: -60)
        s.run(50, rssi: -86)   // 走远 50 秒：不到 60 秒，不撤销
        XCTAssertEqual(s.names(Sim.main), ["lock", "prompt"])
        s.run(20, rssi: -86)   // 持续走远 60 秒才撤销
        s.run(8, rssi: -60)
        XCTAssertEqual(s.names(Sim.main), ["lock", "prompt", "prompt_cancel", "prompt"])
        let ids = s.events.filter { $0.event == "prompt" }.map { String($0.note.prefix(6)) }
        XCTAssertEqual(ids, ["id=101", "id=102"])
    }

    /// 不锁屏模式：只记 would_lock / would_prompt，动键盘鼠标算回来
    func testNoLockMode() {
        let s = Sim(lock: false)
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)
        s.run(8, rssi: -60)
        XCTAssertEqual(s.sys.lockCalls, 0)
        XCTAssertEqual(s.judge.hostState, 3, "不锁屏时按本来会锁屏填心跳，方便测手机通知")
        s.run(1, rssi: -60, active: true)
        XCTAssertEqual(s.names(Sim.main), ["would_lock", "would_prompt", "back"])
        XCTAssertTrue(s.first("back")!.note.contains("动了键盘鼠标"))
    }

    /// 自己锁屏 2 秒后关显示器，只关一次
    func testDisplayOffAfterOwnLock() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)
        let lockT = s.first("lock")!.t
        XCTAssertEqual(s.sys.displayOffs.map { $0 - s.t0 }, [lockT + 2])
        XCTAssertEqual(s.first("display_off")!.t, lockT + 2)
    }

    /// 关屏之前人已经回来解锁了：不关
    func testNoDisplayOffIfUnlockedWithinTwoSeconds() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(60, rssi: -85)   // 第 100 秒锁屏
        XCTAssertEqual(s.sys.lockCalls, 1)
        s.sys.locked = false
        s.run(3, rssi: -60, active: true)
        XCTAssertEqual(s.sys.displayOffs, [])
        XCTAssertNil(s.first("display_off"))
    }

    /// --keep-display、--no-lock、用户自己锁屏：都不关屏
    func testNoDisplayOffOtherwise() {
        let keep = Sim(displayOff: false)
        keep.run(40, rssi: -60, active: true)
        keep.run(80, rssi: -85)
        XCTAssertEqual(keep.sys.lockCalls, 1)
        XCTAssertEqual(keep.sys.displayOffs, [])

        let noLock = Sim(lock: false)
        noLock.run(40, rssi: -60, active: true)
        noLock.run(80, rssi: -85)
        XCTAssertEqual(noLock.sys.displayOffs, [])

        let manual = Sim()
        manual.run(40, rssi: -60, active: true)
        manual.sys.locked = true   // 用户自己锁的，之后才判定离开（"本来就锁着"）
        manual.run(80, rssi: -85)
        XCTAssertTrue(manual.first("lock")!.note.contains("本来就锁着"))
        XCTAssertEqual(manual.sys.displayOffs, [])
    }

    /// 请提示时点亮屏幕；提示后又走远（撤销）就关回去；再回来再点亮
    func testWakeOnPromptAndOffOnCancel() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)   // 锁屏，2 秒后关屏
        XCTAssertEqual(s.sys.displayOffs.count, 1)
        s.run(8, rssi: -60)    // 回来，请提示
        let prompt = s.first("prompt")!
        XCTAssertEqual(s.sys.displayOns.map { $0 - s.t0 }, [prompt.t])
        XCTAssertNotNil(s.first("display_on"))
        s.run(70, rssi: -86)   // 又走远，撤销提示
        XCTAssertNotNil(s.first("prompt_cancel"))
        XCTAssertEqual(s.sys.displayOffs.count, 2)
        s.run(8, rssi: -60)    // 再回来
        XCTAssertEqual(s.sys.displayOns.count, 2)
        XCTAssertEqual(s.names(["prompt", "prompt_cancel", "display_on", "display_off"]),
                       ["display_off", "prompt", "display_on", "prompt_cancel", "display_off", "prompt", "display_on"])
    }

    /// 不锁屏模式、--no-wake：不点亮
    func testNoWakeWithoutLockOrWhenDisabled() {
        let noLock = Sim(lock: false)
        noLock.run(40, rssi: -60, active: true)
        noLock.run(80, rssi: -85)
        noLock.run(8, rssi: -60)
        XCTAssertNotNil(noLock.first("would_prompt"))
        XCTAssertEqual(noLock.sys.displayOns, [])

        let noWake = Sim(wake: false)
        noWake.run(40, rssi: -60, active: true)
        noWake.run(80, rssi: -85)
        noWake.run(8, rssi: -60)
        XCTAssertNotNil(noWake.first("prompt"))
        XCTAssertEqual(noWake.sys.displayOns, [])
    }

    /// 启动 30 秒内手机还没连回来，不算失联
    func testStartupGrace() {
        let s = Sim()
        s.sys.lastInput = s.sys.now - 300   // 早就没人操作
        s.run(1, rssi: -60)                 // 启动后收到过一次报告，之后失联
        s.run(24, rssi: nil)
        XCTAssertNil(s.first("lock"))
        s.run(20, rssi: nil)
        XCTAssertNotNil(s.first("lock"))
    }

    /// 这次启动以来一次报告都没收到（比如 App 还没添加这台电脑）：失联不算离开，坐着不碰电脑也不锁
    func testNoLockIfPhoneNeverReported() {
        let s = Sim()
        s.run(40, rssi: nil, active: true)
        s.run(300, rssi: nil)
        XCTAssertEqual(s.names(Sim.main), [])
        XCTAssertEqual(s.sys.lockCalls, 0)
    }

    /// 以前收到过手机报告（phoneKnown）：电脑端在手机不在时重启，这次启动以来一次报告都没有，失联也照样算离开、锁屏
    /// （不然重启以后就再也不锁了）
    func testKnownPhoneLocksAfterRestartWithoutReports() {
        let s = Sim()
        s.judge.phoneKnown = true
        s.sys.lastInput = s.sys.now - 300
        s.run(25, rssi: nil)
        XCTAssertNil(s.first("lock"), "启动 30 秒内不算失联")
        s.run(20, rssi: nil)
        XCTAssertTrue(s.first("lock")?.note.contains("手机失联") == true)
    }

    /// 手机走后只锁一次：锁屏以后手机还没回来就被解开了（远程解的）→ 之后停下来不再锁；手机回到电脑前恢复，再走开照样锁
    func testLockOnceWhileAwayThenHoldUntilPhoneReturns() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: nil)                     // 带着手机出门 → 锁屏
        XCTAssertEqual(s.sys.lockCalls, 1)
        s.sys.locked = false                     // 人在外面远程解开
        s.run(5, rssi: nil, active: true)
        XCTAssertNotNil(s.first("lock_hold"))
        XCTAssertTrue(s.judge.holdLock)
        s.run(1000, rssi: nil)                   // 远程用着停下来十几分钟：不再锁（也让出门前的信号出了 15 分钟的参考窗口）
        XCTAssertEqual(s.sys.lockCalls, 1)
        XCTAssertEqual(s.events.filter { $0.event == "lock_skip" }.count, 1, "进入离开时记一次，不刷屏")
        s.run(40, rssi: nil, active: true)       // 又操作了一会儿、再停下来：还是不锁，再记一次
        s.run(100, rssi: nil)
        XCTAssertEqual(s.sys.lockCalls, 1)
        XCTAssertEqual(s.events.filter { $0.event == "lock_skip" }.count, 2)
        s.run(10, rssi: -55, active: true)       // 回家，手机回到电脑前 → 恢复
        XCTAssertNotNil(s.first("lock_resume"))
        XCTAssertFalse(s.judge.holdLock)
        s.run(80, rssi: nil)                     // 再出门：照样锁
        XCTAssertEqual(s.sys.lockCalls, 2)
        XCTAssertEqual(s.names(Sim.main), ["lock", "back", "lock"])
    }

    /// 手机回来了、提示后解锁：正常的 back，不进「不再自动锁」，再走开照样锁
    func testNoHoldWhenPhoneIsBack() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: nil)
        s.run(8, rssi: -60)                      // 回来 → 提示
        s.sys.locked = false
        s.run(2, rssi: -60, active: true)        // 解锁
        XCTAssertNil(s.first("lock_hold"))
        s.run(80, rssi: nil)
        XCTAssertEqual(s.sys.lockCalls, 2)
    }

    /// 重启时接上「不再自动锁」：前一个日志最后是 lock_hold，没有 lock_resume；有 lock_resume 就不接
    func testRestoreHold() {
        let s = Sim()
        s.judge.phoneKnown = true
        let t = s.sys.now
        XCTAssertNotNil(s.judge.restoreHold(events: [(t - 900, "lock", ""), (t - 700, "back", ""),
                                                     (t - 700, "lock_hold", "")], now: t))
        XCTAssertTrue(s.judge.holdLock)
        s.sys.lastInput = s.sys.now - 300
        s.run(120, rssi: nil)                    // 重启后手机还不在：不锁
        XCTAssertEqual(s.sys.lockCalls, 0)
        XCTAssertNotNil(s.first("lock_skip"))

        let other = Sim()
        XCTAssertNil(other.judge.restoreHold(events: [(t - 900, "lock_hold", ""), (t - 100, "lock_resume", "")], now: t))
        XCTAssertFalse(other.judge.holdLock)
    }

    /// 提示以后信号偶尔掉下去几秒、或者几秒没报告：不撤销，不重弹
    func testBriefDropoutKeepsPrompt() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)
        s.run(8, rssi: -60)    // 提示
        s.run(40, rssi: -86)   // 走远 40 秒，不到 60 秒
        s.run(5, rssi: -60)
        s.run(8, rssi: nil)    // 8 秒没报告
        s.run(5, rssi: -60)
        XCTAssertEqual(s.names(Sim.main), ["lock", "prompt"])
        XCTAssertEqual(s.judge.hostState, 3)
    }

    /// 自己锁屏后手机走远不到 60 秒又回来：不算走远过，不提示
    func testManualLockShortWalkNoPrompt() {
        let s = Sim()
        s.run(40, rssi: -65, active: true)
        s.sys.locked = true
        s.run(45, rssi: -88)
        s.run(8, rssi: -62)
        XCTAssertEqual(s.names(Sim.main), [])
    }

    /// 回来要信号连续 3 秒 ≥ -72：在 -78 到 -72 之间（别的房间、蓝牙范围边上）不提示，一跳就掉回去也不提示
    func testApproachNeedsStrongSignalForThreeSeconds() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)
        XCTAssertNotNil(s.first("lock"))
        s.run(30, rssi: -76)   // 原来 ≥ -78 就提示
        XCTAssertNil(s.first("prompt"))
        s.run(3, rssi: -65)    // 强了 3 秒又弱下去：中位数第 3 秒才翻上来，又晚 3 秒才翻下去，只在 -72 以上 2 秒
        s.run(3, rssi: -85)
        XCTAssertNil(s.first("prompt"))
        s.run(6, rssi: -65)
        XCTAssertNotNil(s.first("prompt"))
    }

    /// 撤销提示时清掉提示时间：之后用户自己解锁，记「没提示就解锁了」，不是「提示后几百秒解锁」
    func testPromptCancelClearsPromptTime() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)
        s.run(8, rssi: -60)
        s.run(70, rssi: -86)
        XCTAssertNotNil(s.first("prompt_cancel"))
        s.sys.locked = false
        s.run(1, rssi: -86, active: true)
        XCTAssertEqual(s.names(Sim.main), ["lock", "prompt", "prompt_cancel", "back"])
        XCTAssertTrue(s.first("back")!.note.contains("没提示就解锁了"), s.first("back")!.note)
    }

    /// 手机放在卧室，信号整夜在 -82 和 -71 之间来回：比走远时没明显变强，不提示；走到电脑前才提示
    func testBedroomSignalDoesNotPrompt() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)          // 走开，第 100 秒锁屏
        XCTAssertNotNil(s.first("lock"))
        s.run(600, rssi: -73)         // 进了卧室
        for _ in 0..<2 {
            s.run(300, rssi: -82)     // 翻身、被子挡
            s.run(300, rssi: -71)     // 原来 ≥ -72 连续 3 秒就提示
        }
        XCTAssertEqual(s.names(Sim.main), ["lock"], "比走远时（卧室里最强 -71）没强 10 dB，不提示")
        s.run(8, rssi: -55)           // 早上拿着手机走到电脑前
        let prompt = s.first("prompt")!
        XCTAssertTrue(prompt.note.contains("比走远时（-71）强 16 dB"), prompt.note)
    }

    /// 走开一会儿（信号 -85）就回来：走远时的信号只看走开以后的，人坐在电脑前时的信号不算
    func testShortTripStillPrompts() {
        let s = Sim()
        s.run(40, rssi: -55, active: true)
        s.run(30, rssi: -55)          // 人还坐着（信号很强），只是没碰电脑
        s.run(40, rssi: -85)          // 走开，判定离开、锁屏
        XCTAssertNotNil(s.first("lock"))
        s.run(40, rssi: -68)          // 回来时揣在兜里，比坐着时弱，但比走开时强 17 dB
        let prompt = s.first("prompt")!
        XCTAssertTrue(prompt.note.contains("比走远时（-85）"), prompt.note)
    }

    /// 从外面回来（之前一段没有报告）：只看 -72，马上提示
    func testReturnFromOutsidePromptsWithoutReference() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(1200, rssi: nil)        // 出门了
        s.run(3, rssi: -88)           // 门口连上
        s.run(8, rssi: -66)
        let prompt = s.first("prompt")!
        XCTAssertTrue(prompt.note.contains("手机刚连回来"), prompt.note)
    }

    /// 心跳三档：有人用电脑每秒；没人用、信号 < -75 每 3 秒；锁着 30 分钟没碰电脑就休眠，不看信号
    func testHeartbeatTiers() {
        let s = Sim()
        s.appProto = 2
        s.runHeartbeats(40, rssi: -78, active: true)
        XCTAssertEqual(Set(s.intervals), [1], "有人在用电脑，信号再弱也每秒一次")
        s.runHeartbeats(40, rssi: -78)
        XCTAssertEqual(s.intervals.last, 3, "没人用、信号 < -75：3 秒")
        XCTAssertEqual(s.judge.reportTimeout, 5, "失联阈值跟着放宽：3 + (3 - 1)")
        s.sys.locked = true           // 自己锁屏去睡觉，手机在卧室 -72（不算弱）
        s.runHeartbeats(1600, rssi: -72)
        XCTAssertEqual(s.intervals.last, 1, "锁了但还没满 30 分钟没碰电脑：信号不弱，每秒一次")
        XCTAssertFalse(s.intervals.contains(30))
        s.runHeartbeats(200, rssi: -72)
        XCTAssertEqual(s.intervals.last, 30, "锁着、30 分钟没碰电脑：休眠，不管信号")
        XCTAssertEqual(s.judge.reportTimeout, 32)
        XCTAssertTrue(s.judge.summary().contains("休眠"), s.judge.summary())
        s.runHeartbeats(600, rssi: -72)
        XCTAssertEqual(Set(s.intervals.suffix(15)), [30], "一直在卧室：一直休眠")
        s.sys.locked = false          // 早上回来解锁
        s.runHeartbeats(2, rssi: -60, active: true)
        XCTAssertEqual(s.intervals.last, 1)
    }

    /// 没锁屏（人坐着看手机、不碰电脑）：再久也不休眠
    func testNoDormantWhenUnlocked() {
        let s = Sim()
        s.appProto = 2
        s.runHeartbeats(40, rssi: -60, active: true)
        s.runHeartbeats(2400, rssi: -70)
        XCTAssertNil(s.first("lock"))
        XCTAssertEqual(Set(s.intervals), [1])
    }

    /// 变慢先宣布再变：宣布过 1 秒的，下一次还是 1 秒后发
    func testDormantAnnouncedBeforeSlowingDown() {
        let s = Sim(lock: false)
        s.appProto = 2
        s.runHeartbeats(40, rssi: -60, active: true)
        s.runHeartbeats(30, rssi: -60)
        XCTAssertEqual(Set(s.intervals), [1])
        // 手机直接走到很远：中位数翻下来后先 3 秒；判定离开（不锁屏模式算锁着）、30 分钟没碰电脑后 30 秒
        s.runHeartbeats(1900, rssi: -90)
        var deduped: [Double] = []
        for i in s.intervals where deduped.last != i { deduped.append(i) }
        XCTAssertEqual(deduped, [1, 3, 30])
        // 发出宣布 3 秒的那次心跳之后，下一次在 1 秒后发（还按宣布过的 1 秒）——这里每秒一步，所以看不到间隔；
        // 直接测 HeartbeatSchedule
        var sched = HeartbeatSchedule(interval: 1)
        sched.sent(0, interval: 1)
        XCTAssertTrue(sched.due(1, interval: 30), "宣布过 1 秒：1 秒后照发，这一次宣布 30")
        sched.sent(1, interval: 30)
        XCTAssertFalse(sched.due(20, interval: 30))
        XCTAssertTrue(sched.due(31, interval: 30))
        XCTAssertTrue(sched.due(2, interval: 1), "变快马上生效")
    }

    /// 休眠中手机主动报一条（亮屏时 App 报的）：比走远时强 10 dB 才马上回到每秒一次，在卧室里亮屏不算
    func testWakeReportLeavesDormantOnlyWhenClearlyStronger() {
        let s = Sim(lock: false)
        s.appProto = 2
        s.runHeartbeats(40, rssi: -60, active: true)
        s.runHeartbeats(1900, rssi: -88)
        XCTAssertEqual(s.intervals.last, 30)
        s.sys.now += 5
        s.wakeReport(-82)             // 床上拿起手机看一眼：只强了 6 dB
        var before = s.intervals.count
        s.runHeartbeats(10, rssi: -82)
        XCTAssertEqual(s.intervals.count, before, "还在休眠，10 秒里不发")
        s.wakeReport(-70)             // 拿着手机走向电脑：强了 18 dB
        before = s.intervals.count
        // main.swift 每秒判断一次、每 0.25 秒看一次该不该发，这里每秒一步：判断看到这条报告的下一秒发
        s.runHeartbeats(1, rssi: -70)
        XCTAssertLessThan(s.judge.lastMed!, -75, "中位数还没翻过来，只看最新一条")
        s.runHeartbeats(1, rssi: -70)
        XCTAssertEqual(s.intervals.count, before + 1, "1 到 2 秒内就发")
        XCTAssertEqual(s.intervals.last, 1)
    }

    /// 休眠中手机出门了，回来时（之前一段没有报告）马上恢复每秒一次
    func testReconnectLeavesDormant() {
        let s = Sim(lock: false)
        s.appProto = 2
        s.runHeartbeats(40, rssi: -60, active: true)
        s.runHeartbeats(1900, rssi: -88)
        XCTAssertEqual(s.intervals.last, 30)
        s.runHeartbeats(1200, rssi: nil)
        s.runHeartbeats(31, rssi: -85)
        XCTAssertEqual(s.intervals.last, 3, "不休眠了，信号弱按慢档")
        s.runHeartbeats(5, rssi: -66)
        XCTAssertEqual(s.intervals.last, 1)
    }

    /// 旧 App（报告里没写协议版本）最多到慢档，不休眠：它的看门狗固定 5 秒
    func testNoDormantForOldApp() {
        let s = Sim(lock: false)
        s.runHeartbeats(40, rssi: -60, active: true)
        s.runHeartbeats(2000, rssi: -88)
        XCTAssertEqual(Set(s.intervals), [1, 3])
    }

    /// 提示后人在附近待了 5 分钟没解锁、又走开再回来：撤销时「走远的起点」重设成这次走开，回来照样提示
    /// （不重设的话，参考里还有那 5 分钟的强信号，回来的信号和上次一样就不提示了）
    func testRepromptAfterLongStayNear() {
        let s = Sim()
        s.run(40, rssi: -60, active: true)
        s.run(80, rssi: -85)
        s.run(300, rssi: -60)         // 回来提示，但没解锁，在旁边待了 5 分钟
        XCTAssertEqual(s.names(Sim.main), ["lock", "prompt"])
        s.run(70, rssi: -86)          // 又走开，撤销
        s.run(8, rssi: -60)           // 再回来，信号和上次一样
        XCTAssertEqual(s.names(Sim.main), ["lock", "prompt", "prompt_cancel", "prompt"])
    }

    /// 启动时接上前一个进程：锁屏后没 back 就还算离开，正在提示就接着用原来的编号，回来照样提示
    func testRestoreFromPreviousLog() {
        let s = Sim()
        s.sys.lastInput = s.sys.now - 3600
        s.sys.locked = true
        let t = s.sys.now
        let events: [(wall: Double, event: String, note: String)] = [
            (t - 7200, "lock", "空闲 61s，手机失联"), (t - 7000, "back", "离开 200s，没提示就解锁了"),
            (t - 3500, "lock", "空闲 62s，信号 -85"), (t - 600, "prompt", "id=777，离开 2900s 后"),
        ]
        XCTAssertNotNil(s.judge.restore(events: events, now: t, stillLocked: true))
        XCTAssertEqual(s.first("judge_restore")?.note, "3500s 前判定离开，正在提示解锁 id=777")
        XCTAssertEqual(s.judge.promptID, 777)
        s.run(2, rssi: -60)
        XCTAssertEqual(s.judge.hostState, 3, "接着提示，编号不变，手机不重弹")
        s.run(70, rssi: -86)          // 走远，撤销
        s.run(8, rssi: -60)           // 回来，新编号
        XCTAssertEqual(s.names(Sim.main), ["prompt_cancel", "prompt"])
        XCTAssertTrue(s.first("prompt")!.note.hasPrefix("id=778"), s.first("prompt")!.note)
    }

    /// 前一个日志里最后是 back、或者重启期间用户解锁了：不接
    func testRestoreSkipsWhenBackOrUnlocked() {
        let s = Sim()
        let t = s.sys.now
        XCTAssertNil(s.judge.restore(events: [(t - 100, "lock", ""), (t - 50, "back", "")], now: t, stillLocked: true))
        XCTAssertNil(s.judge.restore(events: [(t - 100, "lock", "")], now: t, stillLocked: false), "现在没锁着")
        XCTAssertNil(s.first("judge_restore"))
        XCTAssertNil(s.judge.awayAt)
    }

    /// 卧室里重启：读回最近的报告，参考是卧室的信号，-71 不提示；不读回的话参考是空的，只看 -72，就会提示
    func testRestoredReportsPreventNightPrompt() {
        for withReports in [true, false] {
            let s = Sim()
            s.sys.lastInput = s.sys.now - 7200
            s.sys.locked = true
            let t = s.sys.now
            if withReports {
                for i in 0..<900 { s.recent.append((t - 900 + Double(i), i % 2 == 0 ? -74 : -73)) }
            }
            s.judge.restore(events: [(t - 6000, "lock", "")], now: t, stillLocked: true)
            s.run(10, rssi: -71)
            XCTAssertEqual(s.names(Sim.main).contains("prompt"), !withReports, withReports ? "读回了报告" : "没读回报告")
        }
    }

    func testReference() {
        // 0 到 99 秒：每 10 条里一条 -60（一成），其余 -80
        let tenth: [(wall: Double, rssi: Int)] = (0..<100).map { (Double($0), $0 % 10 == 0 ? -60 : -80) }
        XCTAssertEqual(Judge.reference(tenth, now: 100, start: nil, window: 900), -60, "强的一成算进去（90% 分位）")
        // 每 20 条里一条 -60（半成）：偶尔一跳不算
        let twentieth: [(wall: Double, rssi: Int)] = (0..<100).map { (Double($0), $0 % 20 == 0 ? -60 : -80) }
        XCTAssertEqual(Judge.reference(twentieth, now: 100, start: nil, window: 900), -80, "偶尔一跳不算")
        let split: [(wall: Double, rssi: Int)] = (0..<100).map { (Double($0), $0 < 50 ? -55 : -80) }
        XCTAssertEqual(Judge.reference(split, now: 100, start: nil, window: 900), -55)
        XCTAssertEqual(Judge.reference(split, now: 100, start: 50, window: 900), -80, "只看 start（走开）以后的")
        XCTAssertEqual(Judge.reference(split, now: 100, start: nil, window: 20), -80, "只看最近 window 秒（50 到 70）")
        XCTAssertNil(Judge.reference(split, now: 100, start: 69, window: 900), "最近 30 秒不算，少于 3 条")
        XCTAssertNil(Judge.reference([], now: 100, start: nil, window: 900))
    }

    func testMedianLikePython() {
        let now = 100.0
        XCTAssertEqual(Judge.median([(99, -70), (99, -80)], now: now), -75)
        XCTAssertEqual(Judge.median([(99, -70), (99, 127), (99, -72)], now: now), -71)
        XCTAssertNil(Judge.median([(80, -70)], now: now), "10 秒以前的不算")
        XCTAssertEqual(Judge.median([(50, -70)], now: now, window: 62), -70, "休眠时窗口放宽到 62 秒")
        // 只取最后 5 次
        XCTAssertEqual(Judge.median([(99, -10), (99, -10), (99, -80), (99, -80), (99, -80), (99, -80), (99, -80)], now: now), -80)
        XCTAssertEqual(fmt0(-77.5), "-78")
        XCTAssertEqual(fmt0(-76.5), "-76")
    }
}

final class ProtoTests: XCTestCase {
    /// 和 Python struct.pack("<IBHB", 0x01020304, 3, 0xBEEF, 30) 一样（win_peer.py 是 min(255, ceil(间隔))）
    func testHeartbeatBytes() {
        let d = Proto.heartbeat(seq: 0x0102_0304, hostState: 3, promptID: 0xBEEF, nextWithin: 30)
        XCTAssertEqual([UInt8](d), [0x04, 0x03, 0x02, 0x01, 0x03, 0xEF, 0xBE, 30])
        XCTAssertEqual(Proto.heartbeat(seq: 1, hostState: 1, promptID: 1, nextWithin: 2.5).last, 3)
        XCTAssertEqual(Proto.heartbeat(seq: 1, hostState: 1, promptID: 1, nextWithin: 1000).last, 255)
    }

    /// 和 Python struct.pack("<IbB", 7, -71, 1) 一样；第 7 个字节是 App 的协议版本，再多出来的字节忽略
    func testParseReport() {
        let r = Proto.parseReport(Data([0x07, 0, 0, 0, 0xB9, 0x01, 0x02, 0xFF]))!
        XCTAssertEqual(r.seq, 7)
        XCTAssertEqual(r.rssi, -71)
        XCTAssertEqual(r.phoneState, 1)
        XCTAssertEqual(r.appProto, 2)
        XCTAssertEqual(Proto.parseReport(Data([0x07, 0, 0, 0, 0xB9, 0x01]))!.appProto, 1, "旧 App 没写版本")
        XCTAssertNil(Proto.parseReport(Data([1, 2, 3])))
    }

    func testInfoJSON() throws {
        let data = Proto.info(name: "我的Mac \"mini\"")
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"proto": 1, "platform": "darwin", "name": "我的Mac \"mini\""}"#)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["name"] as? String, "我的Mac \"mini\"")
    }

    /// 读回日志：带 BOM 的表头、引号里的逗号和引号
    func testCSVRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peer_test_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try CSVLog(url: url, t0: 0)
        log.write("info", note: #"{"proto": 1, "name": "a,b"}"#)
        log.write("report", seq: 7, rssi: "-71", phoneState: 1)
        log.close()
        let rows = CSVLog.read(url)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["event"], "info")
        XCTAssertEqual(rows[0]["note"], #"{"proto": 1, "name": "a,b"}"#)
        XCTAssertEqual(rows[1]["rssi"], "-71")
        XCTAssertNotNil(rows[1]["time"])
        XCTAssertEqual(CSVLog.parseLine(#"a,"b,""c""",,d"#), ["a", #"b,"c""#, "", "d"])
    }

    func testCSVEscape() {
        XCTAssertEqual(CSVLog.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVLog.escape(#"{"x": 1}"#), #""{""x"": 1}""#)
        XCTAssertEqual(CSVLog.escape("plain"), "plain")
    }
}
