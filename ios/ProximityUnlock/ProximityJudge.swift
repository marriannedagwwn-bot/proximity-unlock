import Foundation

/// 判断参数，界面上可以调，存在 UserDefaults 里
struct JudgeSettings: Codable, Equatable {
    /// 最近几次 RSSI 的中位数不低于它就算靠近。
    /// 临时放宽到 -76（原来 -70）：揣兜里坐在电脑前是 -68 到 -76，-70 时人回来坐下也一直判成离开
    var nearDbm = -76
    /// 中位数低于它并且持续 awaySeconds 秒就算离开
    var awayDbm = -80
    var awaySeconds = 10
    /// 取最近几次 RSSI 算中位数
    var window = 5

    private static let key = "judge.settings"
    /// 默认值改过以后加一。存下来的还是旧默认值就跟着改，用户自己调过的不动
    private static let defaultsVersionKey = "judge.defaultsVersion"
    private static let defaultsVersion = 2

    static func load() -> JudgeSettings {
        let defaults = UserDefaults.standard
        var s = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(JudgeSettings.self, from: $0) }
        if defaults.integer(forKey: defaultsVersionKey) < defaultsVersion {
            // 2：靠近 -70 → -76（离开阈值调到 -76 以上的不改，靠近要比离开高）
            let near = JudgeSettings().nearDbm
            if var old = s, old.nearDbm == -70, old.awayDbm < near {
                old.nearDbm = near
                old.save()
                s = old
            }
            defaults.set(defaultsVersion, forKey: defaultsVersionKey)
        }
        return s ?? JudgeSettings()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// 手机自己判断靠近还是离开，只写进 REPORT 作参考。
/// 实测揣兜里坐着和去洗手间只差 8 到 10 dB，单靠信号分不清，所以改由电脑结合键盘鼠标活动来判断
/// （`docs/protocol.md`「电脑怎么判断人在不在」）。
///
/// 两个阈值之间不改状态（迟滞），避免在边界上来回跳；断开连接直接算离开。
struct ProximityJudge {
    var settings: JudgeSettings
    private(set) var state: PhoneState = .undetermined
    private var recent: [Int] = []
    private var weakSince: Date?

    init(settings: JudgeSettings) {
        self.settings = settings
    }

    /// 喂一次 RSSI（读不到时传 nil，不计入）。状态变了返回原因，没变返回 nil。
    mutating func feed(_ rssi: Int?, at now: Date) -> String? {
        guard let rssi else { return nil }
        recent.append(rssi)
        if recent.count > max(1, settings.window) {
            recent.removeFirst(recent.count - max(1, settings.window))
        }
        let median = Self.median(recent)

        if median >= settings.nearDbm {
            weakSince = nil
            return change(to: .near, "中位 \(median) ≥ \(settings.nearDbm)")
        }
        if median < settings.awayDbm {
            let since = weakSince ?? now
            weakSince = since
            if now.timeIntervalSince(since) >= Double(settings.awaySeconds) {
                return change(to: .away, "中位 \(median) < \(settings.awayDbm) 持续 \(settings.awaySeconds) 秒")
            }
            return nil
        }
        weakSince = nil
        return nil
    }

    mutating func disconnected() -> String? {
        recent.removeAll()
        weakSince = nil
        return change(to: .away, "断开连接")
    }

    private mutating func change(to new: PhoneState, _ reason: String) -> String? {
        guard state != new else { return nil }
        state = new
        return reason
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : Int((Double(s[mid - 1] + s[mid]) / 2).rounded(.down))
    }
}
