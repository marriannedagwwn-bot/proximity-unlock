// Mac 发 iBeacon 的实验工具（docs/protocol.md「用 iBeacon 拉起 App（实验）」）。
//
// 用 CBPeripheralManager 的私有广播键 kCBAdvDataAppleBeaconKey：16 字节 UUID + major + minor + 1 米处的信号。
// macOS 15.8 实测系统照发（bluetoothd 日志里能看到 4C 00 02 15 开头的厂商数据）。
// 但第三方 App 的广播系统只发一份：同时还有服务 UUID 的广播（比如 MacPeer 在跑）时，iBeacon 被丢掉，
// 所以跑这个工具时别开 MacPeer。
//
// --on / --off 让它轮流发、停，用来测手机进出区域；每次开、停都记进 CSV，和手机日志对时间。
import CoreBluetooth
import Foundation

let usage = """
用法：mac_beacon [--major N] [--minor N] [--power dBm] [--on 秒 --off 秒] [--dir 目录]
  --major / --minor   默认 2 / 1
  --power             1 米处的信号，默认 -59
  --on / --off        轮流发 --on 秒、停 --off 秒；不给 --off 就一直发
  --dir               日志 CSV 写在这里，文件名 beacon_日期_时间_darwin.csv，默认当前目录
Ctrl+C 或 pkill -INT 停止。
"""

struct Args {
    var major: UInt16 = 2
    var minor: UInt16 = 1
    var power: Int8 = -59
    var on: Double = 0
    var off: Double = 0
    var dir = FileManager.default.currentDirectoryPath
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        func value() -> String {
            guard let v = it.next() else { print("\(k) 缺少值\n\(usage)"); exit(2) }
            return v
        }
        switch k {
        case "--major": a.major = UInt16(value()) ?? a.major
        case "--minor": a.minor = UInt16(value()) ?? a.minor
        case "--power": a.power = Int8(value()) ?? a.power
        case "--on": a.on = Double(value()) ?? 0
        case "--off": a.off = Double(value()) ?? 0
        case "--dir": a.dir = value()
        case "-h", "--help": print(usage); exit(0)
        default: print("不认识的参数 \(k)\n\(usage)"); exit(2)
        }
    }
    return a
}

/// 和 App 里 Proto.beaconUUID 一样
let beaconUUID = UUID(uuidString: "9E698AEC-9C56-46E3-9209-F2628704D932")!

final class Log {
    private let handle: FileHandle?
    let path: String
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    init(dir: String) {
        let name = DateFormatter()
        name.locale = Locale(identifier: "en_US_POSIX")
        name.dateFormat = "'beacon_'yyyyMMdd_HHmmss'_darwin.csv'"
        path = (dir as NSString).appendingPathComponent(name.string(from: Date()))
        FileManager.default.createFile(atPath: path, contents: Data("\u{FEFF}time,event,note\r\n".utf8))
        handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
    }

    func write(_ event: String, _ note: String = "") {
        let time = fmt.string(from: Date())
        let escaped = note.contains(",") || note.contains("\"") ? "\"" + note.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : note
        try? handle?.write(contentsOf: Data("\(time),\(event),\(escaped)\r\n".utf8))
        print("\(time) \(event) \(note)")
        fflush(stdout)
    }
}

final class Beacon: NSObject, CBPeripheralManagerDelegate {
    let args: Args
    let log: Log
    var manager: CBPeripheralManager!
    var cycleTimer: Timer?

    init(args: Args, log: Log) {
        self.args = args
        self.log = log
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    var payload: Data {
        var d = Data()
        withUnsafeBytes(of: beaconUUID.uuid) { d.append(contentsOf: $0) }
        d.append(contentsOf: [UInt8(args.major >> 8), UInt8(args.major & 0xff),
                              UInt8(args.minor >> 8), UInt8(args.minor & 0xff), UInt8(bitPattern: args.power)])
        return d
    }

    func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
        let names: [CBManagerState: String] = [.poweredOn: "已打开", .poweredOff: "已关闭", .unauthorized: "没有权限",
                                               .unsupported: "不支持", .resetting: "重置中"]
        log.write("bt_state", names[m.state] ?? "未知")
        cycleTimer?.invalidate()
        guard m.state == .poweredOn else { return }
        turnOn()
    }

    func turnOn() {
        manager.startAdvertising(["kCBAdvDataAppleBeaconKey": payload])
        log.write("beacon_on", "uuid=\(beaconUUID.uuidString) major=\(args.major) minor=\(args.minor) power=\(args.power)")
        if args.off > 0 { schedule(args.on) { self.turnOff() } }
    }

    func turnOff() {
        manager.stopAdvertising()
        log.write("beacon_off", String(format: "停 %.0f 秒", args.off))
        schedule(args.off) { self.turnOn() }
    }

    func schedule(_ seconds: Double, _ block: @escaping () -> Void) {
        cycleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in block() }
    }

    func peripheralManagerDidStartAdvertising(_ m: CBPeripheralManager, error: Error?) {
        if let error { log.write("adv_error", error.localizedDescription) }
    }
}

let args = parseArgs()
let log = Log(dir: args.dir)
log.write("start", "日志 \(log.path)；" + (args.off > 0 ? "轮流发 \(args.on) 秒、停 \(args.off) 秒" : "一直发"))
let beacon = Beacon(args: args, log: log)

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        beacon.manager.stopAdvertising()
        log.write("stop", sig == SIGINT ? "SIGINT" : "SIGTERM")
        exit(0)
    }
    source.resume()
    _ = Unmanaged.passRetained(source)
}
RunLoop.main.run()
