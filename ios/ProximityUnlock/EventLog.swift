import Foundation

/// 把事件记到 CSV，列和电脑端一样：time, t, event, seq, rssi, phone_state, latency_ms, device, note
///
/// 系统会在后台重新拉起 App（蓝牙状态恢复），所以不是每次启动都新建文件，
/// 而是接着写上一次的文件，直到用户点「新建记录」。
final class EventLog {
    static let fields = ["time", "t", "event", "seq", "rssi", "phone_state", "latency_ms", "device", "note"]

    private(set) var url: URL
    private(set) var startedAt: Date
    private var handle: FileHandle?

    private static let fileKey = "log.file"
    private static let startKey = "log.start"

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 和 Python 的 datetime.now().isoformat(timespec="milliseconds") 一样：本地时间，不带时区
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    init() {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: Self.fileKey),
           let start = defaults.object(forKey: Self.startKey) as? Date,
           FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent(name).path) {
            url = Self.directory.appendingPathComponent(name)
            startedAt = start
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        } else {
            (url, startedAt) = (URL(fileURLWithPath: "/dev/null"), Date())
            startNew()
        }
    }

    /// 新建一个记录文件，名字和电脑端对应：phone_日期_时间_ios.csv
    func startNew() {
        try? handle?.close()
        let now = Date()
        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "phone_\(nameFormatter.string(from: now))_ios.csv"
        url = Self.directory.appendingPathComponent(name)
        startedAt = now
        // 带 BOM，和 Windows 端的 utf-8-sig 一样，Excel 直接打开不乱码
        let header = "\u{FEFF}" + Self.fields.joined(separator: ",") + "\r\n"
        FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        UserDefaults.standard.set(name, forKey: Self.fileKey)
        UserDefaults.standard.set(now, forKey: Self.startKey)
    }

    func write(_ event: String, seq: UInt32? = nil, rssi: Int? = nil, state: PhoneState? = nil,
               latencyMs: Int? = nil, device: String = "", note: String = "") {
        let now = Date()
        let values: [String] = [
            timeFormatter.string(from: now),
            String(format: "%.3f", now.timeIntervalSince(startedAt)),
            event,
            seq.map(String.init) ?? "",
            rssi.map(String.init) ?? "",
            state.map { String($0.rawValue) } ?? "",
            latencyMs.map(String.init) ?? "",
            device,
            note,
        ]
        let line = values.map(Self.escape).joined(separator: ",") + "\r\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
