import CoreLocation
import Observation
import UIKit
import UserNotifications

/// iBeacon 实验（docs/protocol.md「用 iBeacon 拉起 App（实验）」）：电脑发 iBeacon，手机做区域监测。
///
/// 蓝牙后台恢复管不到两种情况：App 在多任务界面被划掉、手机重启。区域监测在这两种情况下
/// 也会在走进电脑附近时把 App 在后台拉起来（要「始终」定位权限），拉起来以后 LinkManager 照常连电脑。
/// 区域登记一次系统就一直记着，App 每次启动只要尽早建好 CLLocationManager、设好代理，就能收到事件。
///
/// App 在前台时顺便测距，界面上显示收到的 iBeacon 和信号，用来确认电脑真的在发。
@Observable
final class BeaconWatcher: NSObject {
    struct Seen: Identifiable {
        let major: Int
        let minor: Int
        let rssi: Int
        let proximity: CLProximity
        var id: String { "\(major).\(minor)" }
    }

    let available = CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self)
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// 关了「精确位置」时测不到 iBeacon，区域监测也不灵
    private(set) var precise = true
    private(set) var regionState: CLRegionState = .unknown
    private(set) var regionSince: Date?
    /// 前台测距收到的 iBeacon
    private(set) var seen: [Seen] = []
    /// 区域事件发一条通知（测试用）：不用导出 CSV 也知道 App 有没有被拉起
    private(set) var notifyEvents = UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true

    @ObservationIgnored var log: (String, String) -> Void = { _, _ in }
    /// 被区域事件叫醒（在区域里亮屏、进入区域）：LinkManager 对休眠的电脑主动报一次信号
    @ObservationIgnored var onWake: (String) -> Void = { _ in }
    /// 在不在区域里变了：LinkManager 据此开关找电脑的搜索
    @ObservationIgnored var onRegionChange: () -> Void = {}
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var launchedAt = Date()
    @ObservationIgnored private var launchedForLocation = false
    /// 这次启动是不是被 iBeacon 区域事件拉起的（launchOptions 里没写也算，见 noteLaunchCause）
    @ObservationIgnored private var launchCause = LaunchCause.unknown
    @ObservationIgnored private var becameActive = false
    /// 自己调 requestState 还没回来的次数：它的回复不是系统送来的事件，不能拿来判断启动原因
    @ObservationIgnored private var stateRequests = 0
    @ObservationIgnored private var ranging = false
    @ObservationIgnored private var lastRangeLog: Date?
    @ObservationIgnored private var lastRangeNote = ""
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let notifyKey = "beacon.notify"
    private static let regionID = "proximity-unlock.beacon"
    private static let constraint = CLBeaconIdentityConstraint(uuid: Proto.beaconUUID)

    private static func makeRegion() -> CLBeaconRegion {
        let r = CLBeaconRegion(beaconIdentityConstraint: constraint, identifier: regionID)
        r.notifyOnEntry = true
        r.notifyOnExit = true
        // 在区域里点亮屏幕时也报一次状态（App 没运行也会拉起来）：进区域那一下没赶上时，拿起手机还有一次机会
        r.notifyEntryStateOnDisplay = true
        return r
    }

    /// didFinishLaunching 里调用：系统为区域事件在后台拉起 App 时，要建好 CLLocationManager、设好代理，事件才送过来
    func start(launchedForLocation: Bool) {
        guard manager == nil else { return }
        launchedAt = Date()
        self.launchedForLocation = launchedForLocation
        launchCause = launchedForLocation ? .region : .unknown
        if launchedForLocation { holdBackground() }
        let m = CLLocationManager()
        m.delegate = self
        manager = m
        authorization = m.authorizationStatus
        precise = m.accuracyAuthorization == .fullAccuracy
        let monitored = m.monitoredRegions.contains { $0.identifier == Self.regionID }
        let refresh = [UIBackgroundRefreshStatus.available: "开", .denied: "关", .restricted: "受限"][
            UIApplication.shared.backgroundRefreshStatus] ?? "?"
        log("beacon_setup", "定位权限\(Self.label(authorization))\(precise ? "" : "（模糊位置）")，系统\(monitored ? "记着" : "没记着")iBeacon 区域"
            + "（一共 \(m.monitoredRegions.count) 个区域），后台 App 刷新\(refresh)"
            + (available ? "" : "，这台设备不支持 iBeacon 区域监测"))
        observeAppState()
        // 权限在 locationManagerDidChangeAuthorization 里处理，建好 manager 时系统会先回调一次
    }

    /// 界面上的「允许定位」：没问过就问；只给了「使用期间」就再请求一次「始终」（系统只会再问一次），不行就去设置里改
    func requestAlways() {
        guard let manager else { return }
        switch authorization {
        case .notDetermined, .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    func setNotifyEvents(_ on: Bool) {
        notifyEvents = on
        UserDefaults.standard.set(on, forKey: Self.notifyKey)
    }

    // MARK: - 区域监测和测距

    private func apply() {
        guard let manager, available else { return }
        let monitored = manager.monitoredRegions.contains { $0.identifier == Self.regionID }
        if authorization == .authorizedAlways {
            if monitored {
                requestState(manager, Self.makeRegion())
            } else {
                manager.startMonitoring(for: Self.makeRegion())
                log("beacon_monitor", "开始监测 uuid=\(Proto.beaconUUID.uuidString)")
            }
        }
        updateRanging()
    }

    private func requestState(_ manager: CLLocationManager, _ region: CLRegion) {
        stateRequests += 1
        manager.requestState(for: region)
    }

    /// 只在前台测距：后台测距耗电，也用不着
    private func updateRanging() {
        guard let manager, available else { return }
        let want = UIApplication.shared.applicationState == .active
            && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse)
        guard want != ranging else { return }
        ranging = want
        if want {
            manager.startRangingBeacons(satisfying: Self.constraint)
        } else {
            manager.stopRangingBeacons(satisfying: Self.constraint)
            seen = []
        }
    }

    private func observeAppState() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.becameActive = true
            self?.updateRanging()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateRanging()
        }
    }

    /// 被区域事件拉起、或者在后台进了区域：多要一点后台时间。挂着的蓝牙连接请求系统会接着办，这里只是保险
    private func holdBackground() {
        guard backgroundTask == .invalid, UIApplication.shared.applicationState != .active else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "beacon") { [weak self] in
            self?.endBackground()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.endBackground() }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 系统为区域事件在后台拉起 App 时，launchOptions 里不一定有定位（iOS 18 实测：划掉的 App
    /// 被「离开区域」拉起，launchOptions 是空的，事件在启动 0.0 秒后送到）。所以看启动后马上在后台收到的区域事件：
    /// 启动 2 秒内、还没到过前台、不是自己 requestState 的回复（用户点开 App 时也会马上收到那个回复），就算被它拉起。
    /// 进入、离开区域是确定的；「状态」事件在区域里亮屏时也会送，刚好在别的原因启动时亮屏（比如 devicectl 启动时
    /// 屏幕会亮）也会碰上，所以只写「可能」
    private func noteLaunchCause(_ event: String, certain: Bool = true) {
        // 先来的「状态」只算可能，紧接着来的进入、离开还能改成确定
        guard launchCause == .unknown || (launchCause == .maybeRegion && certain) else { return }
        let since = Date().timeIntervalSince(launchedAt)
        guard !becameActive, since < 2, UIApplication.shared.applicationState == .background else {
            if launchCause == .unknown { launchCause = .other }
            return
        }
        launchCause = certain ? .region : .maybeRegion
        holdBackground()
        log("launch_reason", String(format: "%@系统为 iBeacon 区域事件（%@）在后台拉起的：启动 %.1f 秒后收到，launchOptions 里没写",
                                    certain ? "" : "可能是", event, since)
            + (certain ? "" : "（状态事件在区域里亮屏时也会送，碰巧亮屏时会误判）"))
    }

    /// 区域事件的说明：App 是不是为它刚被拉起来的
    private var launchNote: String {
        let state = UIApplication.shared.applicationState
        let place = state == .active ? "前台" : state == .background ? "后台" : "切换中"
        return String(format: "App 启动 %.1f 秒后，在%@", Date().timeIntervalSince(launchedAt), place)
            + (launchCause == .region ? "，这次是被 iBeacon 区域事件拉起的"
               : launchCause == .maybeRegion ? "，这次可能是被 iBeacon 区域事件拉起的" : "")
    }

    private func notify(_ title: String) {
        guard notifyEvents else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = launchNote
        // 同一个 identifier：通知中心里只留最新一条
        let request = UNNotificationRequest(identifier: "beacon-event", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func setRegion(_ state: CLRegionState) {
        guard state != regionState else { return }
        regionState = state
        regionSince = Date()
        onRegionChange()
    }

    // MARK: - 格式

    static func label(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: "始终"
        case .authorizedWhenInUse: "使用期间"
        case .denied: "不允许"
        case .restricted: "受限"
        default: "没问过"
        }
    }

    static func label(_ state: CLRegionState) -> String {
        switch state {
        case .inside: "在电脑附近"
        case .outside: "不在附近"
        default: "未知"
        }
    }

    static func label(_ p: CLProximity) -> String {
        switch p {
        case .immediate: "很近"
        case .near: "近"
        case .far: "远"
        default: "未知"
        }
    }
}

private enum LaunchCause {
    /// 还没收到区域事件
    case unknown
    /// 被区域事件（进入、离开）拉起，或者 launchOptions 里写了定位
    case region
    /// 启动后马上收到的是「状态」事件：可能是在区域里亮屏拉起的，也可能碰巧亮屏
    case maybeRegion
    /// 不是（到过前台、或者第一个区域事件来得晚）
    case other
}

// MARK: - CLLocationManagerDelegate

extension BeaconWatcher: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let full = manager.accuracyAuthorization == .fullAccuracy
        if status != authorization || full != precise {
            log("loc_auth", "\(Self.label(authorization))\(precise ? "" : "（模糊）") → \(Self.label(status))\(full ? "" : "（模糊）")")
            authorization = status
            precise = full
        }
        apply()
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        log("beacon_monitor", "系统开始监测")
        requestState(manager, region)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        let requested = stateRequests > 0
        if requested {
            stateRequests -= 1
        } else {
            noteLaunchCause("状态：\(Self.label(state))", certain: false)
        }
        log("beacon_state", "\(Self.label(state))；\(launchNote)")
        setRegion(state)
        // 系统送来的「在区域里」：多半是亮屏（notifyEntryStateOnDisplay），进入区域时也会和 didEnterRegion 一起来
        if !requested && state == .inside {
            holdBackground()
            onWake("区域里的状态事件（亮屏或进入区域）")
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        noteLaunchCause("进入区域")
        holdBackground()
        log("beacon_enter", launchNote)
        notify("iBeacon：进入电脑附近")
        setRegion(.inside)
        onWake("进入区域")
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        noteLaunchCause("离开区域")
        log("beacon_exit", launchNote)
        notify("iBeacon：离开电脑附近")
        setRegion(.outside)
    }

    func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon],
                         satisfying constraint: CLBeaconIdentityConstraint) {
        seen = beacons.map {
            Seen(major: $0.major.intValue, minor: $0.minor.intValue, rssi: $0.rssi, proximity: $0.proximity)
        }
        // 测距每秒回调一次，日志里最多 5 秒记一行；收到的 iBeacon 变了马上记
        let note = beacons.isEmpty ? "没收到" : beacons.map { "\($0.major).\($0.minor)" }.joined(separator: " ")
        let now = Date()
        guard note != lastRangeNote || lastRangeLog.map({ now.timeIntervalSince($0) >= 5 }) ?? true else { return }
        lastRangeNote = note
        lastRangeLog = now
        log("beacon_range", beacons.isEmpty ? "没收到 iBeacon"
            : seen.map { "\($0.id) \($0.rssi)dBm \(Self.label($0.proximity))" }.joined(separator: "；"))
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        log("beacon_error", "区域监测失败：\(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didFailRangingFor constraint: CLBeaconIdentityConstraint,
                         error: Error) {
        log("beacon_error", "测距失败：\(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log("beacon_error", error.localizedDescription)
    }
}
