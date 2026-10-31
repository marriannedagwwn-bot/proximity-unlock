// 原型 Mac 电脑端：当蓝牙外设，等 iPhone 来连接，和 prototype/win_peer.py 行为一致
//
// - 广播协议里的服务，iPhone 连上后订阅 HEARTBEAT
// - 每秒发一次心跳（没人用电脑、手机在远处时放慢到 3 秒、休眠 30 秒）；iPhone 每收到一次就测一次信号强度，写回 REPORT
// - 结合键盘鼠标活动判断人在不在：离开就锁屏，回来时请手机提示解锁（PeerCore/Judge.swift）
// - 所有事件记到 CSV，列和事件名和 Windows 端一样
//
// 协议见 docs/protocol.md。编译、运行见 prototype/mac_peer/README.md。

import AppKit
import CoreBluetooth
import Darwin
import Foundation
import MacHost
import PeerCore
import SystemConfiguration

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - 参数（和 win_peer.py 同名、同默认值）

struct Args {
    var duration = 0.0
    var out: String?
    var dir: String?
    /// 默认不加密（见 setupService），--secure 打开
    var secure = false
    var allowSleep = false
    var setupUnlock = false
    /// 后台电脑端收到手机「请求显示登记码」后另起的窗口进程：先问一句，再显示现有登记码或走登记
    var phoneRequest = false
    var forgetUnlock = false
    var screenStatus = false
    var judge = JudgeConfig()

    static let usage = """
    用法：mac_peer [选项]
      --setup-unlock      在本机登记系统解锁凭据，显示给手机离线登记的密钥，然后退出
      --phone-request     和 --setup-unlock 一起：手机请求登记时由电脑端自己起，先确认再显示二维码
      --forget-unlock     删除本机解锁登记，然后退出（之后仍只亮屏）
      --screen-status     只读显示锁屏、辅助功能和当前会话状态，然后退出
      --interval 秒       心跳间隔，默认 1
      --duration 秒       运行多少秒后自动退出，默认一直运行
      --out 路径          日志 CSV 路径，默认 <--dir>/peer_日期_时间_darwin.csv
      --dir 目录          日志目录，默认当前目录
      --secure            要求加密、配对（默认不加密，见 README「配对」）
      --plain             不加密（默认就是，留着兼容以前的命令）
      --pause-after 秒    多少秒没收到报告就停发心跳，等手机自己回应，默认 3（心跳慢下来时跟着放宽）
      --allow-sleep       允许系统空闲睡眠（默认运行期间不让系统睡，显示器照样会关）
    电脑端判断人在不在、锁屏、请手机提示解锁：
      --no-lock           只记录本来会怎么做（would_lock / would_prompt），不真的锁屏
      --keep-display      自己锁屏后不关显示器（默认锁屏 2 秒后关屏）
      --no-wake           请手机提示解锁时不点亮屏幕（默认点亮）
      --active 秒         多少秒内有键盘鼠标操作就算在电脑前，默认 30
      --idle-lock 秒      多少秒没有操作才可能判定离开，默认 60
      --far-th dBm        信号中位数低于它算弱，默认 -80
      --far-for 秒        信号弱持续多少秒算离开，默认 10
      --lost-for 秒       手机失联多少秒算离开，默认 10
      --approach-th dBm   判定离开后，信号中位数回到它以上、并持续 --approach-for 秒，就提示解锁，默认 -72
      --approach-for 秒   见 --approach-th，默认 3
      --approach-gain dB  还要比走远时的信号强这么多才提示（也用来退出休眠），默认 10
      --ref-window 秒     「走远时的信号」看最近多少秒（最近 30 秒不算），取强的那一头（90% 分位），默认 900
      --startup-grace 秒  电脑端启动后多少秒内不算手机失联，默认 30
      --cancel-after 秒   提示解锁以后，手机持续走远多少秒才撤销提示，默认 60；锁屏期间也要走远这么久才会在回来时提示
      --freeze-away 秒    电脑端被系统睡眠冻住多少秒、醒来时锁着（显示器亮了），就当作手机走远过、回来请提示，默认 60
    心跳快慢和休眠（docs/protocol.md「心跳快慢和休眠」）：
      --slow-th dBm       没人在用电脑、信号中位数低于它时，心跳放慢到 --slow-interval，默认 -75
      --slow-interval 秒  见 --slow-th，默认 3
      --dormant-after 秒  锁着、并且多少秒没碰键盘鼠标就休眠（不看信号），默认 1800（30 分钟）
      --dormant-interval 秒  休眠时心跳间隔，默认 30；App 报了协议版本 ≥ 2 才会休眠
    """

    static func parse(_ argv: [String]) -> Args {
        var a = Args()
        var it = argv.makeIterator()
        func value(_ name: String) -> String {
            guard let v = it.next() else { fail("\(name) 后面要跟一个值") }
            return v
        }
        func number(_ name: String) -> Double {
            let v = value(name)
            guard let d = Double(v) else { fail("\(name) 的值 \(v) 不是数字") }
            return d
        }
        while let arg = it.next() {
            switch arg {
            case "--interval": a.judge.interval = number(arg)
            case "--duration": a.duration = number(arg)
            case "--out": a.out = value(arg)
            case "--dir": a.dir = value(arg)
            case "--secure": a.secure = true
            case "--plain": a.secure = false
            case "--pause-after": a.judge.pauseAfter = number(arg)
            case "--allow-sleep": a.allowSleep = true
            case "--setup-unlock": a.setupUnlock = true
            case "--phone-request": a.phoneRequest = true
            case "--forget-unlock": a.forgetUnlock = true
            case "--screen-status": a.screenStatus = true
            case "--no-lock": a.judge.lock = false
            case "--keep-display": a.judge.displayOff = false
            case "--no-wake": a.judge.wakeOnPrompt = false
            case "--active": a.judge.active = number(arg)
            case "--idle-lock": a.judge.idleLock = number(arg)
            case "--far-th": a.judge.farTh = number(arg)
            case "--far-for": a.judge.farFor = number(arg)
            case "--lost-for": a.judge.lostFor = number(arg)
            case "--approach-th": a.judge.approachTh = number(arg)
            case "--approach-for": a.judge.approachFor = number(arg)
            case "--approach-gain": a.judge.approachGain = number(arg)
            case "--ref-window": a.judge.refWindow = number(arg)
            case "--slow-th": a.judge.slowTh = number(arg)
            case "--slow-interval": a.judge.slowInterval = number(arg)
            case "--dormant-after": a.judge.dormantAfter = number(arg)
            case "--dormant-interval": a.judge.dormantInterval = number(arg)
            case "--startup-grace": a.judge.startupGrace = number(arg)
            case "--cancel-after": a.judge.cancelAfter = number(arg)
            case "--freeze-away": a.judge.freezeAway = number(arg)
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                // open 启动 App 时系统可能塞进来 -psn_ 之类的参数
                if arg.hasPrefix("-psn_") { continue }
                fail("不认识的参数 \(arg)\n\(usage)")
            }
        }
        guard [a.setupUnlock, a.forgetUnlock, a.screenStatus].filter({ $0 }).count <= 1 else {
            fail("--setup-unlock、--forget-unlock、--screen-status 一次只能用一个")
        }
        guard !a.phoneRequest || a.setupUnlock else { fail("--phone-request 要和 --setup-unlock 一起用") }
        return a
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

/// 和 Python 的 f"{x:g}" 一样：整数不带小数点
func fmtS(_ x: Double) -> String {
    String(format: "%g", x)
}

func fmtT(_ t: Double) -> String {
    let s = max(0, Int(t))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

func computerName() -> String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
}

// MARK: - 蓝牙外设

final class Peer: NSObject, CBPeripheralManagerDelegate {
    let args: Args
    let t0 = Date().timeIntervalSince1970
    let log: CSVLog
    let system = MacSystem()
    let judge: Judge
    let name = computerName()
    private let credential: StoredUnlockCredential?
    private let unlockGate: UnlockGate?
    private let reportNonce = UnlockProtocol.randomNonce()
    private let authenticatedReports: AuthenticatedReportGate?
    /// 手机让电脑锁屏（App 首页的锁按钮），登记了才有
    private let lockGate: LockGate?
    private var authenticatedSent: [UInt32: Double] = [:]
    private var rejectedReports = 0
    private var lastReportRejectLogAt = -Double.infinity
    lazy var info: Data = {
        let base = Proto.info(name: name)
        guard credential != nil,
              var fields = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return base }
        fields["unlock"] = UnlockProtocol.capability
        fields["reportNonce"] = reportNonce.base64EncodedString()
        // 支持手动解锁（锁着、没在请提示时也给挑战）和手机锁屏（docs/protocol.md「手动锁屏、解锁」）
        fields["manual"] = UnlockProtocol.manualVersion
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? base
    }()

    var manager: CBPeripheralManager!
    var hb: CBMutableCharacteristic!
    var report: CBMutableCharacteristic!
    var infoChar: CBMutableCharacteristic!
    private var challengeChar: CBMutableCharacteristic?
    private var unlockChar: CBMutableCharacteristic?
    private var lockChar: CBMutableCharacteristic?
    /// 手机请求显示登记码：有没有登记都开放（第一次登记也要用）
    private var enrollRequestChar: CBMutableCharacteristic!
    /// 登记确认：和 CHALLENGE / UNLOCK 一起，登记了才有
    private var enrollAckChar: CBMutableCharacteristic?
    /// 手机请求起的登记窗口进程；还开着就不再起第二个
    private var enrollWindow: NSRunningApplication?
    private var lastEnrollLaunch = -Double.infinity
    var serviceAdded = false

    var seq: UInt32 = 0
    /// seq -> 发出时间（相对 t0），用来算往返延迟
    var sent: [UInt32: Double] = [:]
    var clients: [UUID: CBCentral] = [:]
    /// (t, 时间, rssi, 手机状态, 往返延迟毫秒)
    var reports: [(t: Double, wall: Double, rssi: Int, state: UInt8, latency: Double?)] = []
    var last: (rssi: Int, state: UInt8, latency: Double?)?
    var lastReportWall: Double?
    /// 最后一次确认手机有回应（报告、订阅、读 INFO）的时间
    var aliveAt = Date().timeIntervalSince1970
    /// 手机没回应时暂停发心跳，见 heartbeatGate
    var hbPaused = false
    /// App 在报告第 7 个字节里写的协议版本，没写就是 1；≥ 2 才会进休眠
    var appProto = 1
    /// 启动时从前一个日志读回来的最近报告（时间、RSSI），只给判断算「走远时的信号」用，过了 --ref-window 就丢
    var priorReports: [(wall: Double, rssi: Int)] = []
    /// 什么时候发下一次心跳（三档间隔，变慢先宣布再变）
    var schedule: HeartbeatSchedule
    var connectedSince: Double?
    var connectedTotal = 0.0
    var disconnects = 0
    /// updateValue 因为发送队列满而没发出去的次数
    var queueFull = 0
    var activity: NSObjectProtocol?

    init(args: Args) throws {
        self.args = args
        let dir = args.dir ?? {
            // 用 open 启动时当前目录是 /，写不进去
            let cwd = FileManager.default.currentDirectoryPath
            return cwd == "/" ? NSHomeDirectory() : cwd
        }()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "'peer_'yyyyMMdd_HHmmss'_darwin.csv'"
        let path = args.out ?? (dir as NSString).appendingPathComponent(fmt.string(from: Date()))
        log = try CSVLog(url: URL(fileURLWithPath: path), t0: t0)
        var loadFailed = false
        do {
            let stored = args.judge.lock ? try MacUnlockStore.load() : nil
            // 登记只授权当前用户，绝不把另一位用户的密码送进当前登录界面。
            credential = stored.flatMap {
                $0.username == NSUserName() && !$0.password.isEmpty && $0.key.secret.count == 32 ? $0 : nil
            }
            loadFailed = stored != nil && credential == nil
        } catch {
            credential = nil
            loadFailed = true
        }
        unlockGate = credential.map { UnlockGate(key: $0.key) }
        if let credential {
            let longest = max(args.judge.interval, args.judge.slowInterval, args.judge.dormantInterval)
            authenticatedReports = AuthenticatedReportGate(key: credential.key, reportNonce: reportNonce, maximumInterval: longest)
            lockGate = LockGate(key: credential.key, reportNonce: reportNonce, maximumInterval: longest)
        } else {
            authenticatedReports = nil
            lockGate = nil
        }
        judge = Judge(config: args.judge, system: system, started: t0)
        schedule = HeartbeatSchedule(interval: args.judge.interval)
        super.init()
        judge.log = { [unowned self] event, rssi, note in self.log.write(event, rssi: rssi, note: note) }
        judge.say = { [unowned self] in self.say($0) }
        if loadFailed {
            say("解锁登记无法安全读取，保持只亮屏；请在本机重新登记。")
            log.write("unlock_disabled", note: "登记不可用，保持只亮屏")
        } else if credential != nil {
            say("已启用登记手机解锁：只接受本机登记密钥签名的一次性请求（当前提示，或锁着时手机上手动解锁）；手机也能让电脑锁屏。")
            log.write("unlock_enabled", note: UnlockProtocol.capability)
        }
    }

    func now() -> Double { Date().timeIntervalSince1970 - t0 }

    func say(_ msg: String) {
        print("[\(fmtT(now()))] \(msg)")
    }

    func start() {
        // 不让 App Nap 拖慢定时器；默认也不让系统空闲睡眠，否则人一走 Mac 睡了，手机回来时连不上
        let options: ProcessInfo.ActivityOptions = args.allowSleep
            ? [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
            : [.userInitiated, .latencyCritical]
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "和 iPhone 保持蓝牙连接")
        restoreFromPreviousLog()
        manager = CBPeripheralManager(delegate: self, queue: nil)
        // 每 0.25 秒看一次该不该发：间隔会在 1、3、30 秒之间变，变快时要马上生效
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [unowned self] _ in self.heartbeatTick() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in self.judgeTick() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [unowned self] _ in self.status() }
    }

    private func setupService() {
        // 默认不加密：iPhone 和 Mac 是同一个 Apple 账户时，Mac 上的配对是 iCloud 同步来的、
        // 系统设置里看不到，一边丢了配对就再也配不上（Mac 直接拒绝手机的配对请求，README「配对」）。
        // Mac 的蓝牙地址固定，不配对 App 也认得出它；Windows 会换地址，所以 Windows 端还是默认加密。
        // --secure 时要求加密，iPhone 第一次访问时会弹配对请求
        let readPerm: CBAttributePermissions = args.secure ? .readEncryptionRequired : .readable
        let writePerm: CBAttributePermissions = args.secure ? .writeEncryptionRequired : .writeable
        hb = CBMutableCharacteristic(type: CBUUID(string: Proto.heartbeat), properties: [.notify, .read],
                                     value: nil, permissions: readPerm)
        report = CBMutableCharacteristic(type: CBUUID(string: Proto.report), properties: [.write, .writeWithoutResponse],
                                         value: nil, permissions: writePerm)
        infoChar = CBMutableCharacteristic(type: CBUUID(string: Proto.info), properties: [.read],
                                           value: nil, permissions: readPerm)
        enrollRequestChar = CBMutableCharacteristic(type: CBUUID(string: EnrollProtocol.requestUUID), properties: [.write],
                                                    value: nil, permissions: writePerm)
        let service = CBMutableService(type: CBUUID(string: Proto.service), primary: true)
        var characteristics: [CBMutableCharacteristic] = [hb, report, infoChar, enrollRequestChar]
        if credential != nil {
            // 密钥通过本机离线登记，不通过 BLE 暴露；系统配对失配时应用层 HMAC 仍能认证请求。
            let challenge = CBMutableCharacteristic(type: CBUUID(string: UnlockProtocol.challengeUUID),
                                                    properties: [.read], value: nil, permissions: readPerm)
            let command = CBMutableCharacteristic(type: CBUUID(string: UnlockProtocol.commandUUID),
                                                  properties: [.write], value: nil, permissions: writePerm)
            let ack = CBMutableCharacteristic(type: CBUUID(string: EnrollProtocol.ackUUID),
                                              properties: [.write], value: nil, permissions: writePerm)
            let lock = CBMutableCharacteristic(type: CBUUID(string: LockProtocol.uuid),
                                               properties: [.write], value: nil, permissions: writePerm)
            challengeChar = challenge
            unlockChar = command
            enrollAckChar = ack
            lockChar = lock
            characteristics += [challenge, command, ack, lock]
        }
        service.characteristics = characteristics
        manager.removeAllServices()
        manager.add(service)
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
        let names: [CBManagerState: String] = [.poweredOn: "已打开", .poweredOff: "已关闭", .unauthorized: "没有权限",
                                               .unsupported: "不支持", .resetting: "重置中"]
        let label = names[m.state] ?? "未知"
        say("蓝牙\(label)")
        log.write("bt_state", note: label)
        if m.state == .poweredOn {
            setupService()
        } else {
            // 关掉蓝牙时服务和订阅都没了，打开后重新加
            serviceAdded = false
            unlockGate?.sync(promptID: nil, now: ProcessInfo.processInfo.systemUptime)
            authenticatedReports?.clearAllPresence()
            authenticatedSent.removeAll()
            if !clients.isEmpty {
                disconnects += clients.count
                clients.removeAll()
                onDisconnectedAll()
            }
            if m.state == .unauthorized {
                say("没有蓝牙权限：去「系统设置 → 隐私与安全性 → 蓝牙」里打开（在终端里运行时是给终端开，用 open 启动时是给 MacPeer）")
            }
        }
    }

    func peripheralManager(_ m: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            say("加服务失败：\(error.localizedDescription)")
            log.write("add_service_error", note: error.localizedDescription)
            return
        }
        serviceAdded = true
        m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: Proto.service)],
                            CBAdvertisementDataLocalNameKey: name])
        log.write("start", note: "service=\(Proto.service) interval=\(args.judge.interval) secure=\(args.secure) "
                  + "lock=\(args.judge.lock) display_off=\(args.judge.displayOff) wake=\(args.judge.wakeOnPrompt) name=\(name)")
    }

    func peripheralManagerDidStartAdvertising(_ m: CBPeripheralManager, error: Error?) {
        let note = error.map { "失败：\($0.localizedDescription)" } ?? "已开始"
        say("广播\(note)")
        log.write("adv_status", note: note)
    }

    func peripheralManager(_ m: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        guard c.uuid == hb.uuid else { return }
        let isNew = clients[central.identifier] == nil
        if isNew { authenticatedReports?.clearPresence(for: central.identifier) }
        clients[central.identifier] = central
        aliveAt = Date().timeIntervalSince1970
        if connectedSince == nil { connectedSince = now() }
        if isNew {
            say("手机已订阅心跳：\(label(central))")
            log.write("subscribe", device: label(central), note: "最大通知长度 \(central.maximumUpdateValueLength)")
        }
    }

    func peripheralManager(_ m: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        guard c.uuid == hb.uuid else { return }
        authenticatedReports?.clearPresence(for: central.identifier)
        guard clients.removeValue(forKey: central.identifier) != nil else { return }
        disconnects += 1
        say("手机断开：\(label(central))")
        log.write("unsubscribe", device: label(central))
        if clients.isEmpty { onDisconnectedAll() }
    }

    func peripheralManager(_ m: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if let challengeChar, request.characteristic.uuid == challengeChar.uuid {
            guard request.offset == 0 else {
                m.respond(to: request, withResult: .invalidOffset)
                return
            }
            // 未认证中心不能占住挑战，也不能通过让全局门禁失效来清掉其它手机的挑战。
            guard requestHasFreshAuthenticatedReport(request.central),
                  let target = syncUnlockGate(recheckEnrollment: true), let unlockGate else {
                respond(m, to: request, status: .unavailable)
                return
            }
            switch unlockGate.challenge(for: request.central.identifier, now: ProcessInfo.processInfo.systemUptime) {
            case .success(let value):
                request.value = value
                m.respond(to: request, withResult: .success)
                if target == UnlockProtocol.manualPromptID && args.judge.wakeOnPrompt {
                    // 手动解锁：屏幕可能关着（锁屏后关了屏）或在放屏保，先点亮，登录界面的密码框才会出来。
                    // 按提示解锁时请提示那一刻已经点亮过了
                    let r = system.displayOn()
                    log.write("display_on", device: label(request.central), note: r.ok ? "手机要手动解锁" : r.note)
                }
            case .failure(let status): respond(m, to: request, status: status)
            }
            return
        }
        let value: Data
        switch request.characteristic.uuid {
        case hb.uuid:
            value = heartbeatPayload()
        case infoChar.uuid:
            value = info
            aliveAt = Date().timeIntervalSince1970  // App 每次（重新）连上都会读一次 INFO
            log.write("read_info", device: label(request.central))
        default:
            m.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            m.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        m.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ m: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        if requests.count == 1, let request = requests.first {
            if let lockChar, request.characteristic.uuid == lockChar.uuid {
                onLock(request, manager: m)
                return
            }
            if request.characteristic.uuid == enrollRequestChar.uuid {
                onEnrollRequest(request, manager: m)
                return
            }
            if let enrollAckChar, request.characteristic.uuid == enrollAckChar.uuid {
                onEnrollAck(request, manager: m)
                return
            }
        }
        if let unlockChar, requests.contains(where: { $0.characteristic.uuid == unlockChar.uuid }) {
            guard requests.count == 1, let request = requests.first,
                  request.characteristic.uuid == unlockChar.uuid, request.offset == 0 else {
                if let first = requests.first { m.respond(to: first, withResult: .invalidPdu) }
                return
            }
            onUnlock(request, manager: m)
            return
        }
        guard requests.allSatisfy({ $0.characteristic.uuid == report.uuid && $0.offset == 0 }) else {
            if let first = requests.first { m.respond(to: first, withResult: .invalidPdu) }
            return
        }
        var result = CBATTError.Code.success
        for request in requests {
            let data = request.value ?? Data()
            let accepted = onReport(data, from: request.central)
            if !accepted {
                if authenticatedReports != nil && (data.count == 6 || data.count == 7) {
                    // 旧 App / 尚未导入登记的手机：只维持心跳，不能建立设备在场证明。
                    continue
                }
                result = data.count == AuthenticatedReportProtocol.packetLength ? .insufficientAuthorization : .invalidAttributeValueLength
            }
        }
        // 一次回调只回复第一个请求；write without response 的回复系统会忽略
        if let first = requests.first { m.respond(to: first, withResult: result) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers m: CBPeripheralManager) {
        // 发送队列满时 updateValue 返回 false，这里表示又能发了。心跳不补发，下一秒照常
    }

    // MARK: 报告、心跳

    private func label(_ central: CBCentral) -> String {
        "手机（\(central.identifier.uuidString.prefix(8))）"
    }

    /// 每次访问都重新核对系统锁屏，不能只相信一秒前的状态机或手机报来的状态。
    /// 返回现在能解的目标：正在请的提示编号；锁着、没在请提示时是 0（手动解锁，手机上要 Face ID 确认）；不能解是 nil
    @discardableResult
    private func syncUnlockGate(recheckEnrollment: Bool = false) -> UInt16? {
        var enrolled = credential != nil
        if recheckEnrollment, let credential {
            do {
                let current = try MacUnlockStore.load()
                enrolled = current?.username == credential.username && current?.key == credential.key
                    && current?.password == credential.password
            } catch { enrolled = false }
        }
        let reportIsFresh = authenticatedReports?.hasFreshReport(now: ProcessInfo.processInfo.systemUptime,
                                                                currentInterval: judge.currentInterval) ?? false
        let locked = system.screenLocked()
        if !locked { unlockGate?.resetManualFailures() }
        let target: UInt16?
        if !(enrolled && reportIsFresh && args.judge.lock && locked) {
            target = nil
        } else if judge.prompting && judge.hostState == 3 {
            target = UInt16(truncatingIfNeeded: judge.promptID)
        } else {
            target = UnlockProtocol.manualPromptID
        }
        unlockGate?.sync(promptID: target, now: ProcessInfo.processInfo.systemUptime)
        return target
    }

    private func respond(_ manager: CBPeripheralManager, to request: CBATTRequest, status: UnlockStatus) {
        manager.respond(to: request, withResult: CBATTError.Code(rawValue: Int(status.rawValue)) ?? .unlikelyError)
    }

    private func respond(_ manager: CBPeripheralManager, to request: CBATTRequest, enroll status: EnrollRequestStatus) {
        manager.respond(to: request, withResult: CBATTError.Code(rawValue: Int(status.rawValue)) ?? .unlikelyError)
    }

    // MARK: 登记

    /// 手机在 App 里点了「扫码登记」：电脑锁着就回 0x81（锁屏界面上看不到窗口）；登记窗口已经开着就回成功；
    /// 否则另起 MacPeer.app --setup-unlock --phone-request 弹确认窗口。窗口在另一个进程里模态等，不卡这里的蓝牙和心跳。
    /// 显示二维码前一定先问：附近任何设备都能写这个特征（docs/protocol.md「手机请求显示登记码」）
    private func onEnrollRequest(_ request: CBATTRequest, manager m: CBPeripheralManager) {
        let device = label(request.central)
        guard request.offset == 0, request.value == EnrollProtocol.requestPayload else {
            m.respond(to: request, withResult: .invalidAttributeValueLength)
            log.write("enroll_request_reject", device: device, note: "内容不对")
            return
        }
        if system.screenLocked() {
            respond(m, to: request, enroll: .locked)
            log.write("enroll_request_reject", device: device, note: "电脑锁着屏")
            return
        }
        if let window = enrollWindow, !window.isTerminated {
            _ = window.activate(options: [])
            m.respond(to: request, withResult: .success)
            log.write("enroll_request", device: device, note: "登记窗口已经开着")
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastEnrollLaunch < 3 {
            m.respond(to: request, withResult: .success)
            log.write("enroll_request", device: device, note: "3 秒内刚起过窗口，不再起")
            return
        }
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else {
            respond(m, to: request, enroll: .unavailable)
            log.write("enroll_request_reject", device: device, note: "电脑端不是从 MacPeer.app 启动的，弹不出窗口")
            return
        }
        lastEnrollLaunch = uptime
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--setup-unlock", "--phone-request"]
        config.createsNewApplicationInstance = true
        config.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: config) { [weak self] running, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let running {
                    self.enrollWindow = running
                    m.respond(to: request, withResult: .success)
                    self.say("手机请求登记，弹出了确认窗口：\(device)")
                    self.log.write("enroll_request", device: device, note: "弹出了确认窗口")
                } else {
                    self.respond(m, to: request, enroll: .unavailable)
                    self.log.write("enroll_request_reject", device: device,
                                   note: "弹不出窗口：\(error?.localizedDescription ?? "原因不明")")
                }
            }
        }
    }

    /// 登记确认：手机扫码保存后用刚存的密钥签名发来，验过就用 Darwin 通知告诉登记窗口关掉。
    /// 只用来关窗口，不算在场、不能解锁
    private func onEnrollAck(_ request: CBATTRequest, manager m: CBPeripheralManager) {
        let device = label(request.central)
        let data = request.value ?? Data()
        guard request.offset == 0, let keyID = EnrollProtocol.ackKeyID(data) else {
            m.respond(to: request, withResult: .invalidAttributeValueLength)
            log.write("enroll_ack_reject", device: device, note: "长度不对")
            return
        }
        // 刚重新登记换了密钥时这里还是旧密钥（窗口点「完成」才重启电脑端）：现读钥匙串里当前用户的登记再验
        var key = credential?.key
        if key?.id != keyID {
            key = ((try? MacUnlockStore.load()) ?? nil).flatMap { $0.username == NSUserName() ? $0.key : nil }
        }
        guard let key, key.id == keyID, EnrollProtocol.verifyAck(data, key: key, reportNonce: reportNonce) else {
            respond(m, to: request, status: .invalidSignature)
            log.write("enroll_ack_reject", device: device, note: "签名对不上，或者不是本机现在登记的密钥")
            return
        }
        MacUnlockStore.postEnrollAck()
        m.respond(to: request, withResult: .success)
        say("手机确认已保存登记，通知登记窗口关闭：\(device)")
        log.write("enroll_ack", device: device, note: "已通知登记窗口关闭")
    }

    private func requestHasFreshAuthenticatedReport(_ central: CBCentral) -> Bool {
        clients[central.identifier] != nil && (authenticatedReports?.isFresh(for: central.identifier,
                                                                           now: ProcessInfo.processInfo.systemUptime,
                                                                           currentInterval: judge.currentInterval) ?? false)
    }

    private func onUnlock(_ request: CBATTRequest, manager: CBPeripheralManager) {
        guard requestHasFreshAuthenticatedReport(request.central) else {
            respond(manager, to: request, status: .unavailable)
            return
        }
        let target = syncUnlockGate(recheckEnrollment: true)
        let manual = target == UnlockProtocol.manualPromptID
        guard let credential, let unlockGate else {
            respond(manager, to: request, status: .unavailable)
            return
        }
        switch unlockGate.authorize(request.value ?? Data(), from: request.central.identifier,
                                    now: ProcessInfo.processInfo.systemUptime, eligible: target != nil) {
        case .failure(let status):
            log.write("unlock_fail", device: label(request.central),
                      note: "认证拒绝 0x\(String(status.rawValue, radix: 16))" + (manual ? "（手动解锁）" : ""))
            respond(manager, to: request, status: status)
        case .success:
            log.write("unlock_request", device: label(request.central),
                      note: manual ? "手动解锁：一次性签名已核对（电脑没在请提示，手机用户在 App 里点了解锁）"
                                   : "当前提示的一次性签名已核对")
            // 等待 AX 操作和真实锁屏状态确认；Task 的等待不会阻塞蓝牙 delegate 或主队列心跳。
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.system.unlockScreen(password: credential.password)
                let ok = result.ok && !self.system.screenLocked()
                unlockGate.finish(succeeded: ok)
                self.log.write(ok ? "unlock" : "unlock_fail", device: self.label(request.central),
                               note: (ok ? "系统已确认解锁" : "系统解锁未成功，需在电脑上手动解锁") + (manual ? "（手动解锁）" : ""))
                if ok {
                    manager.respond(to: request, withResult: .success)
                    self.judgeTick()
                } else {
                    self.respond(manager, to: request, status: .executionFailed)
                }
            }
        }
    }

    /// 手机让电脑锁屏（App 首页的锁按钮，docs/protocol.md「手动锁屏、解锁」）：核对登记密钥的签名、
    /// 心跳 seq 是这次进程真发过、没过期的，不重放。本来就锁着也回成功。锁上 2 秒后关显示器，和电脑端自己锁屏一样。
    /// 判断那边当作用户自己锁的屏：手机一直在旁边就不会请提示，要手机上手动解锁，或者带着手机走开 1 分钟再回来
    private func onLock(_ request: CBATTRequest, manager m: CBPeripheralManager) {
        let device = label(request.central)
        guard request.offset == 0, args.judge.lock, let lockGate, requestHasFreshAuthenticatedReport(request.central) else {
            respond(m, to: request, status: .unavailable)
            log.write("phone_lock_reject", device: device, note: "这条连接还没有通过认证的报告，或者没开真的锁屏")
            return
        }
        let data = request.value ?? Data()
        let uptime = ProcessInfo.processInfo.systemUptime
        let sentAt = LockProtocol.sequence(data).flatMap { authenticatedSent[$0] }
        if case .failure(let reason) = lockGate.accept(data, sentAt: sentAt, now: uptime, currentInterval: judge.currentInterval) {
            switch reason {
            case .invalidFormat: m.respond(to: request, withResult: .invalidAttributeValueLength)
            case .wrongKey, .invalidSignature: respond(m, to: request, status: .invalidSignature)
            case .staleHeartbeat, .replay: respond(m, to: request, status: .invalidChallenge)
            case .invalidConfiguration: respond(m, to: request, status: .unavailable)
            }
            log.write("phone_lock_reject", device: device, note: "\(reason)")
            return
        }
        if system.screenLocked() {
            m.respond(to: request, withResult: .success)
            log.write("phone_lock", device: device, note: "本来就锁着")
            return
        }
        let r = system.lockScreen()
        guard r.ok else {
            respond(m, to: request, status: .executionFailed)
            log.write("phone_lock_fail", device: device, note: r.note)
            return
        }
        m.respond(to: request, withResult: .success)
        say("⇒ 手机让电脑锁屏：\(device)")
        log.write("phone_lock", device: device, note: "已锁屏")
        if args.judge.displayOff {
            // 等锁屏界面出来再关，免得被锁屏动画重新点亮
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.system.screenLocked() else { return }
                let r = self.system.displayOff()
                self.say(r.ok ? "⇒ 已关屏" : "⇒ 关屏失败")
                self.log.write("display_off", note: r.ok ? "手机锁屏" : r.note)
            }
        }
        judgeTick()
    }

    private func onReport(_ data: Data, from central: CBCentral) -> Bool {
        let wall = Date().timeIntervalSince1970
        let payload: Data
        if let authenticatedReports {
            let uptime = ProcessInfo.processInfo.systemUptime
            let sentAt = AuthenticatedReportProtocol.sequence(data).flatMap { authenticatedSent[$0] }
            switch authenticatedReports.accept(data, from: central.identifier, sentAt: sentAt,
                                               now: uptime, currentInterval: judge.currentInterval) {
            case .success(let base):
                payload = base
            case .failure:
                // 旧版/未登记手机仍可维持心跳以完成离线登记，但不能影响信号、判断或解锁门禁。
                aliveAt = wall
                rejectedReports += 1
                if uptime - lastReportRejectLogAt >= 30 {
                    log.write("report_auth_reject", note: "拒绝 \(rejectedReports) 条未通过认证的报告；不用于判断")
                    lastReportRejectLogAt = uptime
                    rejectedReports = 0
                }
                return false
            }
        } else {
            payload = data
        }
        guard let r = Proto.parseReport(payload) else {
            log.write("bad_report", note: data.map { String(format: "%02x", $0) }.joined())
            return false
        }
        let t = now()
        let latency = sent[r.seq].map { (t - $0) * 1000 }
        reports.append((t, wall, r.rssi, r.phoneState, latency))
        if reports.count > 20000 { reports.removeFirst(reports.count - 20000) }
        last = (r.rssi, r.phoneState, latency)
        lastReportWall = wall
        appProto = r.appProto
        aliveAt = wall
        log.write("report", seq: r.seq, rssi: String(r.rssi), phoneState: r.phoneState,
                  latencyMs: latency.map(fmt0) ?? "", device: clients[central.identifier].map(label) ?? "",
                  note: authenticatedReports == nil ? "" : "auth=v3")
        return true
    }

    func heartbeatPayload(nextWithin: Double? = nil) -> Data {
        Proto.heartbeat(seq: seq, hostState: judge.hostState, promptID: judge.promptID,
                        nextWithin: nextWithin ?? judge.currentInterval)
    }

    /// 手机几秒没回报告就停发心跳，直到它自己有回应（报告、重新订阅、读 INFO）。
    /// Windows 上实测往一条正在断开或已经断开的连接上发心跳，调用可能永远不完成，所以不试探。
    /// Mac 上没验证过会不会这样，先照同样做。手机那边 5 秒收不到心跳会自己重连，重连时读 INFO，这里就恢复了
    private func heartbeatGate(_ wall: Double) -> Bool {
        let quiet = wall - aliveAt
        if quiet <= judge.reportTimeout {
            if hbPaused {
                hbPaused = false
                say("手机有回应了，恢复心跳")
                log.write("hb_resume")
            }
            return true
        }
        if !hbPaused {
            hbPaused = true
            say("手机 \(fmt0(quiet)) 秒没回报告，停发心跳，等它回应")
            log.write("hb_pause", note: String(format: "%.1fs 没回报告", quiet))
        }
        return false
    }

    private func heartbeatTick() {
        let wall = Date().timeIntervalSince1970
        let interval = judge.heartbeatInterval(now: wall)
        guard schedule.due(wall, interval: interval),
              serviceAdded, !clients.isEmpty, heartbeatGate(wall) else { return }
        if interval != schedule.announced {
            log.write("hb_rate", rssi: judge.lastMed.map(fmt0) ?? "",
                      note: "心跳间隔 \(fmtS(schedule.announced))s → \(fmtS(interval))s"
                          + (interval >= args.judge.dormantInterval ? "（休眠）" : ""))
        }
        schedule.sent(wall, interval: interval)
        judge.currentInterval = interval
        seq &+= 1
        sent[seq] = now()
        sent.removeValue(forKey: seq &- 600)
        let start = Date()
        let ok = manager.updateValue(heartbeatPayload(nextWithin: interval), for: hb, onSubscribedCentrals: nil)
        if authenticatedReports != nil {
            let uptime = ProcessInfo.processInfo.systemUptime
            let maximumAge = max(10, max(args.judge.interval, args.judge.slowInterval, args.judge.dormantInterval) + 5)
            authenticatedSent = authenticatedSent.filter { uptime - $0.value <= maximumAge }
            if ok { authenticatedSent[seq] = uptime }
        }
        let dt = Date().timeIntervalSince(start) * 1000
        if !ok { queueFull += 1 }
        log.write("hb", seq: seq, note: "ok=\(ok ? clients.count : 0)/\(clients.count) dt=\(fmt0(dt))ms" + (ok ? "" : " 发送队列满"))
    }

    private func judgeTick() {
        // 「走远时的信号」要看最近 --ref-window 秒的报告，所以多给一点
        let wall = Date().timeIntervalSince1970
        let since = wall - args.judge.refWindow - 60
        var recent: [(wall: Double, rssi: Int)] = []
        for r in reports.reversed() {
            if r.wall < since && recent.count >= 5 { break }
            recent.append((r.wall, r.rssi))
        }
        // 刚启动时接上前一个进程的报告（restoreFromPreviousLog），都比这次收到的早
        priorReports.removeAll { $0.wall < since }
        let snapshot = LinkSnapshot(hasClients: !clients.isEmpty, lastReportWall: lastReportWall,
                                    recent: priorReports + recent.reversed(), appProto: appProto)
        judge.update(link: snapshot, now: wall)
        syncUnlockGate()
    }

    /// 启动时接上前一个进程（同一个目录里上一个日志）的判断：最后一次锁屏之后还没有 back 就还算离开、
    /// 接着用原来的提示编号，并读回最近 --ref-window + 60 秒的报告。和 win_peer.py 卡死重启后的 judge_restore 一样，
    /// Mac 端是 launchd 在意外退出后重启、或者改了代码重装时用得上。不读的话「走远时的信号」是空的，提示只看 -72
    private func restoreFromPreviousLog() {
        let dir = log.url.deletingLastPathComponent()
        let current = log.url.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let previous = names.filter({ $0.hasPrefix("peer_") && $0.hasSuffix("_darwin.csv") && $0 < current }).max()
        else {
            notePhoneKnown(lastReport: nil)
            return
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let wall = Date().timeIntervalSince1970
        let since = wall - args.judge.refWindow - 60
        var events: [(wall: Double, event: String, note: String)] = []
        var prior: [(wall: Double, rssi: Int)] = []
        var lastReport: Double?
        for row in CSVLog.read(dir.appendingPathComponent(previous)) {
            guard let time = row["time"].flatMap(fmt.date(from:))?.timeIntervalSince1970, let event = row["event"] else { continue }
            if event == "report" {
                lastReport = time
                if time >= since, let rssi = row["rssi"].flatMap({ Int($0) }) { prior.append((time, rssi)) }
            } else {
                // 前一个进程启动时记的「上次收到报告」：连着重启几次、中间都没收到报告也接得上
                if event == "phone_known", let r = row["note"]?.range(of: #"last=(\d+)"#, options: .regularExpression),
                   let last = Double(row["note"]![r].dropFirst(5)) {
                    lastReport = max(lastReport ?? 0, last)
                }
                events.append((time, event, row["note"] ?? ""))
            }
        }
        notePhoneKnown(lastReport: lastReport)
        // 「不再自动锁」只会让电脑少锁、不会多解锁，自动解锁启用时也接
        judge.restoreHold(events: events, now: wall)
        // 旧 CSV 没有可重验的会话签名。自动解锁启用后从新认证报告重新判断，不能继承旧 prompt 或信号。
        guard credential == nil else { return }
        priorReports = prior
        judge.restore(events: events, now: wall, stillLocked: system.screenLocked())
        if !prior.isEmpty {
            say("从 \(previous) 读回最近 \(prior.count) 条报告（算「走远时的信号」用）")
            log.write("restore_reports", note: "\(previous) 最近 \(prior.count) 条")
        }
    }

    /// 这台电脑以前收到过手机报告（7 天内），或者登记过解锁的手机：这次启动以来还没收到报告时，失联也算离开。
    /// 记一行 phone_known（带上次收到报告的时间），下次启动接着用
    private func notePhoneKnown(lastReport: Double?) {
        let now = Date().timeIntervalSince1970
        let recent = lastReport.map { now - $0 <= 7 * 86400 } == true
        judge.phoneKnown = credential != nil || recent
        guard judge.phoneKnown else { return }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MM-dd HH:mm"
        let seen = lastReport.map { "上次收到手机报告是 \(fmt.string(from: Date(timeIntervalSince1970: $0)))" } ?? "登记过解锁的手机"
        say("\(seen)：手机还没连上时，失联也算离开")
        log.write("phone_known", note: "\(seen)，这次启动以来还没收到报告时失联也算离开"
                  + (lastReport.map { " last=\(Int($0))" } ?? ""))
    }

    private func onDisconnectedAll() {
        if let since = connectedSince {
            connectedTotal += now() - since
            connectedSince = nil
        }
    }

    // MARK: 状态、退出

    func status() {
        let t = now()
        let recent = reports.filter { $0.t > t - 10 }
        var line: String
        if clients.isEmpty {
            line = "等待手机订阅心跳…"
        } else if let last {
            let lat = last.latency.map { "\(fmt0($0))ms" } ?? "-"
            let phone = [0: "未定", 1: "靠近", 2: "离开"][Int(last.state)] ?? "\(last.state)"
            line = "已连接 | 最近 10 秒收到 \(recent.count) 次报告 | 信号 \(last.rssi) | 手机判断 \(phone) | 往返延迟 \(lat)"
        } else {
            line = "已连接 \(clients.count) 台，还没收到信号报告"
        }
        line += " | " + judge.summary()
        say(line)
    }

    func stop() {
        unlockGate?.sync(promptID: nil, now: ProcessInfo.processInfo.systemUptime)
        manager?.stopAdvertising()
        onDisconnectedAll()
        log.write("stop")
        log.close()
        summary()
    }

    private func summary() {
        print("")
        print("本次运行到 \(fmtT(now()))，连接时长 \(fmtT(connectedTotal))，断开 \(disconnects) 次")
        if !reports.isEmpty {
            let times = reports.map(\.t)
            let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
            let lats = reports.compactMap(\.latency).sorted()
            let rate = connectedTotal > 0 ? Double(reports.count) / connectedTotal : 0
            print("收到报告 \(reports.count) 次，连接期间平均 \(String(format: "%.2f", rate)) 次/秒"
                  + (gaps.isEmpty ? "" : String(format: "，最长间隔 %.1fs", gaps.max()!)))
            if !lats.isEmpty {
                print("往返延迟：中位 \(fmt0(lats[lats.count / 2]))ms，最长 \(fmt0(lats.last!))ms")
            }
            let valid = reports.map(\.rssi).filter { $0 != Proto.rssiUnavailable }.sorted()
            if !valid.isEmpty {
                print("信号：中位 \(valid[valid.count / 2])，最强 \(valid.last!)，最弱 \(valid.first!)")
            }
        }
        if queueFull > 0 { print("心跳因发送队列满没发出去 \(queueFull) 次") }
        print("日志：\(log.url.path)")
    }
}

// MARK: - 入口

let args = Args.parse(Array(CommandLine.arguments.dropFirst()))

// 一次性本机操作在文件锁之前处理，也不会建立蓝牙 manager 或触碰用户的锁屏状态。
do {
    if args.setupUnlock {
        let done = args.phoneRequest ? try MacUnlockStore.configureForPhoneRequest()
            : try MacUnlockStore.configureInteractively()
        print(done ? "解锁登记已保存或已显示。" : "已取消解锁登记。")
        exit(0)
    }
    if args.forgetUnlock {
        try MacUnlockStore.delete()
        print("本机解锁登记已删除；已运行的电脑端会拒绝后续解锁请求。")
        exit(0)
    }
    if args.screenStatus {
        print(MacSystem.diagnosticStatus())
        exit(0)
    }
} catch {
    fail("本机解锁配置未完成；原有蓝牙和只亮屏模式不受影响。")
}

// 同一个用户只跑一份：两份会各加一个同样的协议服务，手机可能拿到另一份（见 App 的「旧服务」）。
// 用文件锁，进程退出（包括崩溃、被强制结束）时系统自动放开
let lockPath = NSHomeDirectory() + "/Library/Caches/proximity-unlock/mac_peer.lock"
try? FileManager.default.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print("已经有一个 Mac 电脑端在运行（可能是登录时自动启动的那个），这个不再启动。")
    exit(0)
}

let peer: Peer
do {
    peer = try Peer(args: args)
} catch {
    fail("打不开日志文件：\(error.localizedDescription)")
}

print("服务 UUID：\(Proto.service)，电脑名：\(peer.name)")
if args.secure {
    print("--secure 要求加密：没配对过的 iPhone 第一次连接时会弹「蓝牙配对请求」，点「配对」；Mac 上如果弹出配对提示，也要允许。")
}
print(args.judge.lock ? "判定离开会真的锁屏（--no-lock 只记录）。" : "--no-lock：只记录本来会怎么做，不真的锁屏。")
print("日志：\(peer.log.url.path)")
peer.start()

// Ctrl+C、kill 时记一行 stop 再退出
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        peer.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}
if args.duration > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + args.duration) {
        peer.stop()
        exit(0)
    }
}
RunLoop.main.run()
