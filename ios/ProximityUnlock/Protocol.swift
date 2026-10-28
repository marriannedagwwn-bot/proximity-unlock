import CoreBluetooth

/// 蓝牙协议 v1.2，见 docs/protocol.md。改这里要同步改文档和电脑端。
enum Proto {
    /// App 的协议版本，写进 REPORT 的第 7 个字节：2 表示认识心跳里的「下一次最晚几秒」，电脑端才会进休眠。
    /// INFO 里电脑端报的版本比它新时界面上提示；比它旧没关系（v0 电脑端的心跳只是没有提示编号）
    static let version = 2

    static let service = CBUUID(string: "74cb8b6c-6eb7-4eed-bbcd-0a37f0ac77d7")
    static let heartbeat = CBUUID(string: "2399f9b5-b3ca-43ee-966d-d669401a5ed4")
    static let report = CBUUID(string: "ba3e7281-d451-4a7f-a305-150c789f1460")
    static let info = CBUUID(string: "a82beb9a-cba0-4974-8df3-2c8cf3052899")
    static let unlockChallenge = CBUUID(string: "0c28c82e-69ec-4cd1-ab3b-ea7e160fcd3c")
    static let unlockCommand = CBUUID(string: "54cd9a6f-36e3-4c39-b875-bbeee5f1aef1")
    /// 登记确认（ENROLL_ACK）：手机保存登记后写一次，电脑的登记窗口收到就自己关。登记了的电脑才有
    static let enrollAck = CBUUID(string: "be282b23-6b55-4b86-86ea-b7f8f3c273e3")
    /// 请电脑显示登记码（ENROLL_REQUEST）：点「扫码登记」时写一次 0x01，电脑先确认再弹出二维码。有没有登记都有
    static let enrollRequest = CBUUID(string: "3465d7ce-93d4-4d36-9c16-0619b8ebadbf")

    /// 电脑发的 iBeacon 的 UUID（实验，docs/protocol.md「用 iBeacon 拉起 App（实验）」）。major、minor 还没定，App 只按 UUID 监测
    static let beaconUUID = UUID(uuidString: "9E698AEC-9C56-46E3-9209-F2628704D932")!

    /// REPORT 里读不到 RSSI 时填的值
    static let rssiUnavailable: Int8 = 127
}

/// 手机自己判断的状态，写进 REPORT 的最后一个字节
enum PhoneState: UInt8 {
    case undetermined = 0
    case near = 1
    case away = 2

    var label: String {
        switch self {
        case .undetermined: "未定"
        case .near: "靠近"
        case .away: "离开"
        }
    }
}

/// 心跳里的电脑状态（v0 电脑端固定发 0）
enum ComputerState {
    static let unknown: UInt8 = 0
    static let unlocked: UInt8 = 1
    static let locked: UInt8 = 2
    /// 已锁屏，请手机提示解锁
    static let promptUnlock: UInt8 = 3

    static func label(_ state: UInt8) -> String {
        switch state {
        case unknown: "未知"
        case unlocked: "未锁屏"
        case locked: "已锁屏"
        case promptUnlock: "已锁屏，请提示解锁"
        default: "\(state)（不认识）"
        }
    }
}

/// HEARTBEAT，v1.2 是 8 字节 `<IBHB`：seq、电脑状态、提示编号、下一次心跳最晚几秒后到。
/// v1 电脑端只有前 7 字节（没有最后一个，按 1 秒一次算），v0 只有前 5 字节（也没有提示编号）
struct Heartbeat {
    let seq: UInt32
    let computerState: UInt8
    let promptID: UInt16?
    let nextWithin: UInt8?

    init(seq: UInt32, computerState: UInt8, promptID: UInt16?, nextWithin: UInt8? = nil) {
        self.seq = seq
        self.computerState = computerState
        self.promptID = promptID
        self.nextWithin = nextWithin
    }

    init?(_ data: Data) {
        guard data.count >= 5 else { return nil }
        let b = [UInt8](data.prefix(8))
        seq = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        computerState = b[4]
        promptID = b.count >= 7 ? UInt16(b[5]) | UInt16(b[6]) << 8 : nil
        nextWithin = b.count >= 8 ? b[7] : nil
    }
}

/// REPORT，v1.2 是 7 字节 `<IbBB`：触发这次测量的心跳 seq、RSSI、手机判断的状态、App 的协议版本。
/// 电脑端忽略认不得的字节，旧电脑端只读前 6 个
struct Report {
    let seq: UInt32
    let rssi: Int8
    let state: PhoneState

    var data: Data {
        var d = Data(capacity: 7)
        withUnsafeBytes(of: seq.littleEndian) { d.append(contentsOf: $0) }
        d.append(UInt8(bitPattern: rssi))
        d.append(state.rawValue)
        d.append(UInt8(Proto.version))
        return d
    }
}

/// INFO，UTF-8 JSON，例如 `{"proto": 0, "platform": "win32", "name": "电脑名"}`
struct ComputerInfo: Decodable {
    let proto: Int?
    let platform: String?
    let name: String?
    /// 显式配置了解锁的电脑才声明能力；只接受 UnlockCapability 中列出的平台/能力组合。
    let unlock: String?
    /// v3 每次电脑端进程启动重新生成的 16 字节随机数（base64），认证 RSSI 报告使用。
    let reportNonce: String?
}
