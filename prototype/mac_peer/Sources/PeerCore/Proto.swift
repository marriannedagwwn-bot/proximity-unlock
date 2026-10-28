import Foundation

/// 蓝牙协议 v1.2，见 docs/protocol.md。和 prototype/win_peer.py、ios/ProximityUnlock/Protocol.swift 保持一致。
public enum Proto {
    /// INFO 里的 proto，和 Windows 端一样还写 1
    public static let version = 1

    public static let service = "74cb8b6c-6eb7-4eed-bbcd-0a37f0ac77d7"
    public static let heartbeat = "2399f9b5-b3ca-43ee-966d-d669401a5ed4"
    public static let report = "ba3e7281-d451-4a7f-a305-150c789f1460"
    public static let info = "a82beb9a-cba0-4974-8df3-2c8cf3052899"

    /// REPORT 里读不到 RSSI 时填的值
    public static let rssiUnavailable = 127

    /// HEARTBEAT，8 字节 `<IBHB`（v1.2）：seq、电脑状态（1 未锁屏 2 已锁屏 3 请提示解锁）、提示编号、
    /// 下一次心跳最晚几秒后到（App 的看门狗按它放宽，见 docs/protocol.md「心跳快慢和休眠」）
    public static func heartbeat(seq: UInt32, hostState: UInt8, promptID: Int, nextWithin: Double) -> Data {
        var d = Data(capacity: 8)
        withUnsafeBytes(of: seq.littleEndian) { d.append(contentsOf: $0) }
        d.append(hostState)
        withUnsafeBytes(of: UInt16(truncatingIfNeeded: promptID).littleEndian) { d.append(contentsOf: $0) }
        d.append(UInt8(min(255, max(0, nextWithin.rounded(.up)))))
        return d
    }

    /// REPORT，6 字节 `<IbB`：心跳 seq、RSSI、手机判断的状态；v1.2 的 App 在后面加一个字节写自己的协议版本，
    /// 没有就是 1（≥ 2 才会进休眠）。再往后多出来的字节忽略
    public static func parseReport(_ data: Data) -> (seq: UInt32, rssi: Int, phoneState: UInt8, appProto: Int)? {
        guard data.count >= 6 else { return nil }
        let b = [UInt8](data.prefix(7))
        let seq = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return (seq, Int(Int8(bitPattern: b[4])), b[5], b.count >= 7 ? Int(b[6]) : 1)
    }

    /// INFO，UTF-8 JSON，例如 `{"proto": 1, "platform": "darwin", "name": "电脑名"}`
    public static func info(name: String) -> Data {
        let fields: [(String, Any)] = [("proto", version), ("platform", "darwin"), ("name", name)]
        // 照 Python json.dumps 的样子拼，键的顺序固定
        let body = fields.map { key, value -> String in
            let v = value is String ? jsonString(value as! String) : "\(value)"
            return "\"\(key)\": \(v)"
        }.joined(separator: ", ")
        return Data("{\(body)}".utf8)
    }

    private static func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}

/// 日志 CSV：列和 Windows 端、手机端一样，带 BOM，每行立刻写盘
public final class CSVLog {
    public static let fields = ["time", "t", "event", "seq", "rssi", "phone_state", "latency_ms", "device", "note"]

    public let url: URL
    private let t0: Double
    private let handle: FileHandle
    private let timeFormatter: DateFormatter

    public init(url: URL, t0: Double) throws {
        self.url = url
        self.t0 = t0
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: url.path) || ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) == 0
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        if isNew {
            // 和 Windows 端的 utf-8-sig 一样，Excel 直接打开不乱码
            handle.write(Data(("\u{FEFF}" + Self.fields.joined(separator: ",") + "\r\n").utf8))
        }
    }

    public func write(_ event: String, seq: UInt32? = nil, rssi: String = "", phoneState: UInt8? = nil,
                      latencyMs: String = "", device: String = "", note: String = "", now: Date = Date()) {
        let values = [timeFormatter.string(from: now), String(format: "%.3f", now.timeIntervalSince1970 - t0), event,
                      seq.map(String.init) ?? "", rssi, phoneState.map(String.init) ?? "", latencyMs, device, note]
        handle.write(Data((values.map(Self.escape).joined(separator: ",") + "\r\n").utf8))
    }

    public func close() {
        try? handle.close()
    }

    /// 读回一个日志（启动时接上前一个进程的判断用），每行一个「列名 → 值」。读不了返回空
    public static func read(_ url: URL) -> [[String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard !lines.isEmpty else { return [] }
        let header = parseLine(lines.removeFirst().replacingOccurrences(of: "\u{FEFF}", with: ""))
        return lines.map { line in
            Dictionary(zip(header, parseLine(line)), uniquingKeysWith: { a, _ in a })
        }
    }

    /// 拆一行 CSV：和 escape 反过来（引号里的逗号不拆，两个引号是一个引号）
    static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var cur = ""
        var quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" {
                        cur.append("\"")
                        chars.removeFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    cur.append(c)
                }
            } else if c == "," {
                fields.append(cur)
                cur = ""
            } else if c == "\"" && cur.isEmpty {
                quoted = true
            } else {
                cur.append(c)
            }
        }
        fields.append(cur)
        return fields
    }

    /// 和 Python csv 模块一样：有逗号、引号、换行时加引号，引号写两次
    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// 和 Python 的 f"{x:.0f}" 一样（四舍六入五成双）
public func fmt0(_ x: Double) -> String {
    String(format: "%.0f", x)
}
