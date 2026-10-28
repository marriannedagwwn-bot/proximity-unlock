import CoreBluetooth
import Observation
import UIKit
import UserNotifications

/// 搜索时看到的、还没添加的电脑
struct FoundComputer: Identifiable {
    let id: UUID
    /// INFO 里的名字。广播包放不下名字（只有服务 UUID），要连上读
    var name: String?
    /// 广播或系统缓存里的名字，读到 INFO 之前先显示它
    var advertisedName: String?
    var rssi: Int
    /// 连上读名字没成功（连不上、没点配对、没有 INFO）
    var nameFailed = false
}

/// 位置标签，和 rssi_probe.py 的默认标签一样，类别是 near / mid / far / mix / skip
struct Place: Identifiable, Hashable {
    let name: String
    let cls: String
    var id: String { name }

    static let all = [
        Place(name: "桌上", cls: "near"), Place(name: "兜里", cls: "near"),
        Place(name: "1米", cls: "mid"), Place(name: "3米", cls: "far"),
        Place(name: "门口", cls: "far"), Place(name: "隔壁", cls: "far"),
        Place(name: "日常", cls: "mix"), Place(name: "暂停", cls: "skip"),
    ]
}

/// 跟着记录文件走：系统在后台重新拉起 App 时接着累计，点「新建记录」才清零。所有电脑合计
struct SessionStats: Codable {
    var heartbeats = 0
    var missed = 0
    var seqResets = 0
    /// RSSI 还没读完时又来了两次以上心跳，较早的那次不回 REPORT
    var skipped = 0
    var rssiFailed = 0
    var writeErrors = 0
    var disconnects = 0
    var lastReconnectSeconds: Double?

    private static let key = "log.stats"

    static func load(for file: String) -> SessionStats {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([String: SessionStats].self, from: data),
              let stats = saved[file] else { return SessionStats() }
        return stats
    }

    func save(for file: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode([file: self]), forKey: Self.key)
    }
}

/// 正在连上读 INFO 的设备
private struct Probe {
    let peripheral: CBPeripheral
    let started: Date
}

/// 管 central 和所有记住的电脑（docs/protocol.md「iPhone 端流程」）。
///
/// 每台电脑一个 ComputerLink，各自连接、订阅心跳、读 RSSI、写 REPORT、看门狗。这里管的是大家共用的：
/// 蓝牙开关、后台状态恢复、按服务 UUID 搜索（添加电脑、找换了地址的电脑）、连上读 INFO 看名字，
/// 以及日志文件、统计、位置标记和判断参数。
@Observable
final class LinkManager: NSObject {
    static let shared = LinkManager()

    private(set) var bluetoothState: CBManagerState = .unknown
    /// 记住的电脑，按添加的顺序
    private(set) var computers: [ComputerLink] = []
    /// 搜索时看到的、还没添加的电脑
    private(set) var found: [FoundComputer] = []
    /// 界面上开着「添加电脑」
    private(set) var adding = false
    private(set) var scanning = false
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// 所有电脑合计，ComputerLink 也会累加
    var stats = SessionStats()

    private(set) var place: Place?
    private(set) var placeSince: Date?
    /// 这一段里每台电脑读到的 RSSI，按电脑的 key 分开
    private(set) var placeRSSI: [UUID: [Int]] = [:]
    /// 标签是从上次运行恢复的：这一段的统计只算重启以后的
    private(set) var placeRestored = false

    private(set) var settings = JudgeSettings.load()
    private(set) var logURL: URL
    private(set) var logStartedAt: Date
    private(set) var isSimulated = false

    @ObservationIgnored private let log = EventLog()
    @ObservationIgnored let prompter = UnlockPrompter()
    @ObservationIgnored let beacon = BeaconWatcher()
    @ObservationIgnored private(set) var central: CBCentralManager!
    /// 搜索到的外设要自己留着引用，否则系统会释放掉，连不上
    @ObservationIgnored private var discovered: [UUID: CBPeripheral] = [:]
    /// 正在连上读 INFO 的设备：给搜索列表读名字，或者核对是不是换了地址的电脑（见下面「读名字」）
    @ObservationIgnored private var probes: [UUID: Probe] = [:]
    /// 读到过的 INFO 名字
    @ObservationIgnored private var infoNames: [UUID: String] = [:]
    /// 连不上、读不出名字的设备，到这个时间以前不再试
    @ObservationIgnored private var rejected: [UUID: Date] = [:]
    /// 搜索是为了什么，变了记一行 scan_start
    @ObservationIgnored private var scanPurpose = ""
    /// 忘记了的电脑的日志名：撤通知的那行日志是异步记的，那时它已经不在列表里了
    @ObservationIgnored private var forgottenLabels: [UUID: String] = [:]

    private static let computersKey = "computers"
    private static let restoreID = "proximity-unlock.central"
    private static let placeKey = "place.name"
    private static let placeSinceKey = "place.since"

    override init() {
        logURL = log.url
        logStartedAt = log.startedAt
        stats = SessionStats.load(for: log.url.lastPathComponent)
        // CSV 里标签一直生效到下一个标签，App 被系统重新拉起后界面也要接着显示
        if let name = UserDefaults.standard.string(forKey: Self.placeKey),
           let restored = Place.all.first(where: { $0.name == name }) {
            place = restored
            placeSince = UserDefaults.standard.object(forKey: Self.placeSinceKey) as? Date
            placeRestored = true
        }
        super.init()
        computers = Self.loadComputers().map { ComputerLink(owner: self, saved: $0, settings: settings) }
        prompter.log = { [weak self] event, key, note in
            guard let self else { return }
            let device = key.flatMap { self.computer(key: $0)?.deviceLabel ?? self.forgottenLabels[$0] }
            self.record(event, device: device ?? "", note: note)
        }
        prompter.onAuthorization = { [weak self] status in self?.notificationStatus = status }
        prompter.onUnlock = { [weak self] key, promptID in
            self?.computer(key: key)?.requestUnlock(promptID: promptID)
        }
        beacon.log = { [weak self] event, note in self?.record(event, note: note) }
        // 被区域事件叫醒：休眠的电脑 30 秒才来一次心跳，主动报一次信号，人走回来时电脑马上知道（ComputerLink「休眠」）
        beacon.onWake = { [weak self] reason in
            for link in self?.computers ?? [] { link.wakeReport(reason) }
        }
        beacon.onRegionChange = { [weak self] in self?.onBeaconRegion() }
    }

    /// 在 didFinishLaunching 里调用：系统在后台拉起 App 恢复蓝牙、或者为 iBeacon 区域事件拉起 App 时，
    /// 要马上用同一个恢复 ID 建 central、建好 CLLocationManager
    func start(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        guard central == nil else { return }
        let forLocation = launchOptions?[.location] != nil
        var reasons: [String] = []
        if forLocation { reasons.append("定位") }
        if launchOptions?[.bluetoothCentrals] != nil { reasons.append("蓝牙") }
        // 用了 scene，这时候 applicationState 总是 background，分不出是不是用户打开的：用户打开的话紧接着会有 app_active。
        // 被 iBeacon 区域事件拉起时 launchOptions 里也可能没有定位，那时紧接着会有 launch_reason（BeaconWatcher）
        let how = reasons.isEmpty ? "launchOptions 里没写原因（用户打开时后面有 app_active，被 iBeacon 拉起时后面有 launch_reason）"
            : "系统在后台唤醒（" + reasons.joined(separator: "、") + "）"
        let keys = (launchOptions ?? [:]).keys.map(\.rawValue).sorted()
        record("app_launch", note: how
               + (computers.isEmpty ? "，还没记住电脑"
                  : "，记住 \(computers.count) 台电脑：" + computers.map(\.deviceLabel).joined(separator: "、"))
               + (keys.isEmpty ? "" : "；launchOptions: " + keys.joined(separator: " ")))
        record("settings", note: settingsNote)
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
        beacon.start(launchedForLocation: forLocation)
        observeAppState()
    }

    // MARK: - 界面操作

    /// 「添加电脑」打开：搜索，搜到的连上读名字
    func startAdding() {
        adding = true
        refreshFound()
        updateScan()
    }

    func stopAdding() {
        adding = false
        updateScan()
    }

    func add(_ id: UUID) {
        guard let p = discovered[id], computer(id: id) == nil else { return }
        let name = infoNames[id]
        let saved = SavedComputer(key: id, id: id, name: name ?? found.first(where: { $0.id == id })?.advertisedName,
                                  infoName: name)
        let link = ComputerLink(owner: self, saved: saved, settings: settings)
        computers.append(link)
        saveComputers()
        found.removeAll { $0.id == id }
        probes[id] = nil  // 正在读名字的连接直接交给它，不断开
        rejected[id] = nil
        record("add", device: link.deviceLabel,
               note: "id=\(id.uuidString)，现在记住 \(computers.count) 台" + (name == nil ? "；还没读到 INFO 里的名字" : ""))
        link.take(p)
        updateScan()
    }

    func forget(_ link: ComputerLink) {
        forgottenLabels[link.key] = link.deviceLabel
        link.forget()
        prompter.forget(link.key)
        computers.removeAll { $0 === link }
        placeRSSI[link.key] = nil
        saveComputers()
        updateScan()
    }

    /// 搜索列表里这台和已经添加的某台电脑同名（同一台电脑换了地址又出现）
    func isAdded(_ found: FoundComputer) -> Bool {
        guard let name = found.name else { return false }
        return computers.contains { $0.infoName == name }
    }

    func mark(_ place: Place) {
        self.place = place
        placeSince = Date()
        placeRSSI = [:]
        placeRestored = false
        UserDefaults.standard.set(place.name, forKey: Self.placeKey)
        UserDefaults.standard.set(placeSince, forKey: Self.placeSinceKey)
        record("label", note: "\(place.name):\(place.cls)")
    }

    func notePlaceRSSI(_ value: Int, for key: UUID) {
        guard let place, place.cls != "skip" else { return }
        placeRSSI[key, default: []].append(value)
    }

    func newLog() {
        log.startNew()
        logURL = log.url
        logStartedAt = log.startedAt
        stats = SessionStats()
        record("log_start", note: computers.map { "\($0.deviceLabel) \(Self.phaseNote($0))" }.joined(separator: "；"))
        record("settings", note: settingsNote)
        if let place { mark(place) }
    }

    func updateSettings(_ s: JudgeSettings) {
        settings = s
        s.save()
        for link in computers { link.apply(s) }
        record("settings", note: settingsNote)
    }

    func sendTestPrompt() {
        prompter.sendTest(computerName: computers.first?.name)
    }

    private var settingsNote: String {
        let s = settings
        return "near≥\(s.nearDbm) away<\(s.awayDbm) 持续\(s.awaySeconds)s window=\(s.window)"
    }

    // MARK: - 搜索
    //
    // 只有一个扫描（按服务 UUID），两种用途：界面上在添加电脑（还没记住任何电脑时也算），
    // 或者有记住的电脑没连上（系统取不回它，或者它换了地址）。两样都不需要了就停。
    // 不在 iBeacon 区域里（人出门了）时不找没连上的电脑：电脑不在附近，搜也搜不到，白耗电。
    // 挂着的连接请求由系统在蓝牙芯片里维持，回来时照样连上；进入区域再接着找。App 在前台时照常找

    /// 确定不在 iBeacon 区域里，并且 App 在后台
    private var awayFromBeacon: Bool {
        beacon.regionState == .outside && UIApplication.shared.applicationState != .active
    }

    func updateScan() {
        guard let central, central.state == .poweredOn, !isSimulated else { return }
        var purposes: [String] = []
        if adding || computers.isEmpty { purposes.append("添加电脑") }
        let lost = computers.filter { $0.phase != .connected }
        let lostNames = lost.map { $0.name ?? "未知" }.joined(separator: "、")
        if !lost.isEmpty && !awayFromBeacon {
            purposes.append("找没连上的电脑（可能换了地址）：" + lostNames)
        }
        let purpose = purposes.joined(separator: "；")
        if purpose.isEmpty {
            guard scanning else { return }
            central.stopScan()
            scanning = false
            scanPurpose = ""
            record("scan_stop", note: lost.isEmpty ? "" : "不在 iBeacon 区域里，先不找没连上的电脑（连接请求还挂着）：" + lostNames)
            return
        }
        if !scanning || !central.isScanning {
            central.scanForPeripherals(withServices: [Proto.service],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scanning = true
        }
        if purpose != scanPurpose {
            scanPurpose = purpose
            record("scan_start", note: purpose)
        }
    }

    /// 进出 iBeacon 区域：出了区域停搜索，核对到一半的也不核对了（电脑不在附近，连不上）；进了区域接着找
    private func onBeaconRegion() {
        updateScan()
        guard awayFromBeacon, !adding else { return }
        for probe in Array(probes.values) { rejectProbe(probe.peripheral, "不在 iBeacon 区域里，不核对了", failed: false) }
    }

    private func refreshFound() {
        found.removeAll()
        guard let central, central.state == .poweredOn else { return }
        // 系统已经连着的（比如别的 App 连的、正在读名字的）不会再广播，要单独取
        for p in central.retrieveConnectedPeripherals(withServices: [Proto.service]) where computer(id: p.identifier) == nil {
            discovered[p.identifier] = p
            noteFound(p.identifier, advertisedName: p.name, rssi: 0)
            considerProbe(p, rssi: 0)
        }
    }

    private func noteFound(_ id: UUID, advertisedName: String?, rssi: Int) {
        if let i = found.firstIndex(where: { $0.id == id }) {
            found[i].rssi = rssi
            if let advertisedName { found[i].advertisedName = advertisedName }
        } else {
            found.append(FoundComputer(id: id, name: infoNames[id], advertisedName: advertisedName, rssi: rssi))
            record("found", device: probeLabel(id), rssi: rssi,
                   note: "id=\(id.uuidString)" + (advertisedName.map { "，广播名「\($0)」" } ?? ""))
        }
    }

    // MARK: - 读名字：搜索列表显示真名，兜底找换了地址的电脑
    //
    // 广播包放不下电脑名，搜索列表原来只能显示「未命名」。所以搜到带协议服务的设备就连上读 INFO：
    // 添加电脑时给列表显示名字；有记住的电脑没连上时，名字和它记住的一样就改连这台（adopt），并更新记住的 identifier。
    // 后者对付的是 Windows 不配对时每次断开、重启都换广播地址，iPhone 当成一台新设备，
    // 挂着的连接请求永远等不到（docs/protocol.md 第 4 个问题）。
    // v0 只靠名字核对，能被冒充；配对以后系统自己能认出换了地址的电脑，用不到这里。
    // 电脑要求加密时，读 INFO 会弹配对请求。

    private func considerProbe(_ p: CBPeripheral, rssi: Int) {
        let id = p.identifier
        guard probes[id] == nil else { return }
        if let until = rejected[id], until > Date() { return }
        let lost = computers.filter { $0.phase != .connected && $0.infoName != nil }
        let reason: String
        if let known = infoNames[id] {
            // 名字已经读过了：只有对得上没连上的电脑时才再连（那台电脑断开后换到了这个地址）
            guard let link = lost.first(where: { $0.infoName == known }) else { return }
            reason = "核对是不是换了地址的「\(link.name ?? known)」"
        } else if !lost.isEmpty {
            reason = "核对是不是换了地址的" + lost.map { "「\($0.infoName ?? "")」" }.joined(separator: "或")
        } else if adding || computers.isEmpty {
            reason = "读电脑名，搜索列表里显示"
        } else {
            return
        }
        guard probes.count < 3 else { return }
        let probe = Probe(peripheral: p, started: Date())
        probes[id] = probe
        p.delegate = self
        central.connect(p, options: nil)
        record("candidate", device: probeLabel(id), rssi: rssi, note: "id=\(id.uuidString)，连上读 INFO：\(reason)")
        // 配对弹窗可能要等用户点，留够时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.probes[id]?.started == probe.started else { return }
            self.rejectProbe(p, "30 秒内没核对完")
        }
    }

    /// 不再读这台：断开连接。failed 是没读到名字，60 秒内不再试；读到了名字的以后按名字决定要不要再连
    private func rejectProbe(_ p: CBPeripheral, _ reason: String, failed: Bool = true) {
        guard probes.removeValue(forKey: p.identifier) != nil else { return }
        if failed {
            rejected[p.identifier] = Date().addingTimeInterval(60)
            if let i = found.firstIndex(where: { $0.id == p.identifier }) { found[i].nameFailed = true }
        }
        central.cancelPeripheralConnection(p)
        record("candidate_reject", device: probeLabel(p.identifier), note: "id=\(p.identifier.uuidString)：\(reason)")
    }

    private func cancelProbes() {
        for probe in probes.values { central.cancelPeripheralConnection(probe.peripheral) }
        probes.removeAll()
    }

    private func onProbeInfo(_ p: CBPeripheral, _ data: Data) {
        guard let name = (try? JSONDecoder().decode(ComputerInfo.self, from: data))?.name, !name.isEmpty else {
            rejectProbe(p, "INFO 里读不出名字：\(String(decoding: data, as: UTF8.self))")
            return
        }
        infoNames[p.identifier] = name
        if let i = found.firstIndex(where: { $0.id == p.identifier }) {
            found[i].name = name
            found[i].nameFailed = false
        }
        if let link = computers.first(where: { $0.phase != .connected && $0.infoName == name }) {
            // 名字对上了：这条连接直接交给那台电脑
            probes[p.identifier] = nil
            found.removeAll { $0.id == p.identifier }
            link.adopt(p)
            return
        }
        let what = computers.contains(where: { $0.infoName == name }) ? "是已经添加的电脑，它正连着" : "不是没连上的电脑"
        rejectProbe(p, "INFO 里的名字是「\(name)」，\(what)", failed: false)
    }

    private func probeLabel(_ id: UUID) -> String {
        "\(infoNames[id] ?? "未知")（\(id.uuidString.prefix(8))）"
    }

    // MARK: - 记住的电脑

    private func computer(key: UUID) -> ComputerLink? {
        computers.first { $0.key == key }
    }

    /// 记住的 identifier 或者正在连的外设是这个 id
    private func computer(id: UUID) -> ComputerLink? {
        computers.first { $0.savedID == id || $0.peripheral?.identifier == id }
    }

    private func computer(owning p: CBPeripheral) -> ComputerLink? {
        computers.first { $0.peripheral === p }
    }

    private static func loadComputers() -> [SavedComputer] {
        let d = UserDefaults.standard
        if let data = d.data(forKey: computersKey),
           let saved = try? JSONDecoder().decode([SavedComputer].self, from: data) {
            return saved
        }
        // 旧版本一次只记一台：computer.id / computer.name / computer.infoName，搬过来
        guard let id = d.string(forKey: "computer.id").flatMap(UUID.init(uuidString:)) else { return [] }
        let name = d.string(forKey: "computer.name")
        // 更早的版本只存了 computer.name，读过 INFO 以后它就是 INFO 里的名字
        let infoName = d.string(forKey: "computer.infoName") ?? (name == "未命名" ? nil : name)
        let migrated = [SavedComputer(key: id, id: id, name: name, infoName: infoName)]
        d.set(try? JSONEncoder().encode(migrated), forKey: computersKey)
        for old in ["computer.id", "computer.name", "computer.infoName"] { d.removeObject(forKey: old) }
        return migrated
    }

    func saveComputers() {
        guard !isSimulated else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(computers.map(\.saved)), forKey: Self.computersKey)
    }

    // MARK: - 记录

    private static func phaseNote(_ link: ComputerLink) -> String {
        switch link.phase {
        case .bluetoothUnavailable: "蓝牙不可用"
        case .searching: "搜索中"
        case .connecting: "等待连接"
        case .connected: link.subscribed ? "已连接" : "已连接，未订阅"
        }
    }

    func record(_ event: String, device: String = "", seq: UInt32? = nil, rssi: Int? = nil, state: PhoneState? = nil,
                latencyMs: Int? = nil, note: String = "") {
        log.write(event, seq: seq, rssi: rssi, state: state, latencyMs: latencyMs, device: device, note: note)
        // 统计每次变化后都会紧跟着记一行事件，在这里顺手存下来
        stats.save(for: logURL.lastPathComponent)
    }

    private func observeAppState() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.record("app_active")
            self?.prompter.refreshAuthorization()
            self?.computers.forEach { $0.refreshUnlockAuthorization() }
            self?.updateScan()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.record("app_background")
            self?.updateScan()  // 在 iBeacon 区域外，前台时照常找，到后台就停
        }
        // 这两个只在手机设了密码时才有
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.record("phone_locked")
        }
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.record("phone_unlocked")
            self?.computers.forEach { $0.refreshUnlockAuthorization() }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LinkManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        record("restore", note: "系统恢复了 \(restored.count) 个外设："
               + restored.map { "\($0.identifier.uuidString) state=\($0.state.rawValue)" }.joined(separator: "; "))
        // 每台记住的电脑接回自己的；读名字读到一半的设备不算，蓝牙打开后取消
        for p in restored {
            if let link = computers.first(where: { $0.savedID == p.identifier }) {
                link.restore(p)
            } else {
                probes[p.identifier] = Probe(peripheral: p, started: Date())
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        record("bt_state", note: central.state.label)
        #if targetEnvironment(simulator)
        if central.state == .unsupported {
            startSimulation()
            return
        }
        #endif
        guard central.state == .poweredOn else {
            scanning = false
            scanPurpose = ""
            for link in computers { link.bluetoothUnavailable(central.state) }
            if central.state != .unknown {
                discovered.removeAll()
                probes.removeAll()
            }
            return
        }
        cancelProbes()
        for link in computers { link.resume() }
        if adding || computers.isEmpty { refreshFound() }
        updateScan()
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discovered[p.identifier] = p
        if let link = computer(id: p.identifier) {
            link.discovered(p)
            return
        }
        if adding || computers.isEmpty {
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
            noteFound(p.identifier, advertisedName: name, rssi: RSSI.intValue)
        }
        considerProbe(p, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        if probes[p.identifier] != nil {
            record("candidate_connect", device: probeLabel(p.identifier), note: "id=\(p.identifier.uuidString)")
            p.discoverServices([Proto.service])
            return
        }
        guard let link = computer(owning: p) else {
            central.cancelPeripheralConnection(p)  // 忘记了的电脑
            return
        }
        link.didConnect(p)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if probes[p.identifier] != nil {
            rejectProbe(p, "连不上：\(error?.localizedDescription ?? "")")
            return
        }
        computer(owning: p)?.didFailToConnect(p, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if probes[p.identifier] != nil {
            rejectProbe(p, "核对完之前断开了：\(error?.localizedDescription ?? "")")
            return
        }
        // 「忘记这台电脑」以后它就不在列表里了，不再重连
        computer(owning: p)?.didDisconnect(p, error: error)
    }
}

// MARK: - CBPeripheralDelegate（只管读名字的连接，记住的电脑各自是自己外设的代理）

extension LinkManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard probes[p.identifier] != nil else { return }
        if let service = p.services?.first(where: { $0.uuid == Proto.service }) {
            p.discoverCharacteristics([Proto.info], for: service)
        } else {
            rejectProbe(p, "没有协议服务")
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard probes[p.identifier] != nil else { return }
        if let info = service.characteristics?.first(where: { $0.uuid == Proto.info }) {
            p.readValue(for: info)  // 电脑要求加密时，这一步会弹配对请求
        } else {
            rejectProbe(p, "没有 INFO 特征值")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard probes[p.identifier] != nil else { return }
        if let error {
            rejectProbe(p, "读 INFO 失败：\(error.localizedDescription)")
        } else if c.uuid == Proto.info, let data = c.value {
            onProbeInfo(p, data)
        }
    }
}

extension CBManagerState {
    var label: String {
        switch self {
        case .poweredOn: "已打开"
        case .poweredOff: "已关闭"
        case .unauthorized: "没有权限"
        case .unsupported: "不支持"
        case .resetting: "重置中"
        default: "未知"
        }
    }
}

// MARK: - 模拟器

#if targetEnvironment(simulator)
extension LinkManager {
    /// 模拟器里没有蓝牙。用两台假电脑各自每秒发心跳，把界面、通知和 CSV 跑起来，数据全是假的。
    /// 两台的锁屏周期不一样长，请提示解锁的时间段有时重叠、有时错开，用来看通知是不是各弹各的、各撤各的。
    fileprivate func startSimulation() {
        guard !isSimulated else { return }
        isSimulated = true
        record("simulate", note: "模拟器没有蓝牙，两台假电脑，以下数据都是假的")
        let fakes: [(SavedComputer, String, UInt32, UInt32, Double)] = [
            (SavedComputer(key: UUID(uuidString: "51A00001-0000-4000-8000-000000000001")!,
                           id: UUID(uuidString: "51A00001-0000-4000-8000-000000000001")!,
                           name: "DESKTOP-SIM", infoName: "DESKTOP-SIM"), "win32", 40, 0, -58),
            (SavedComputer(key: UUID(uuidString: "51A00002-0000-4000-8000-000000000002")!,
                           id: UUID(uuidString: "51A00002-0000-4000-8000-000000000002")!,
                           name: "模拟的Mac mini", infoName: "模拟的Mac mini"), "darwin", 24, 10, -70),
        ]
        computers = fakes.map { ComputerLink(owner: self, saved: $0.0, settings: settings, simulated: true) }
        for (link, fake) in zip(computers, fakes) {
            link.startSimulation(platform: fake.1, cycle: fake.2, offset: fake.3, level: fake.4)
            record("simulate", device: link.deviceLabel, note: "每 \(fake.2) 秒走一轮未锁屏 → 已锁屏 → 请提示解锁")
        }
    }
}
#endif
