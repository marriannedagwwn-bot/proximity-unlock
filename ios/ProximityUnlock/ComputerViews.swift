import Charts
import SwiftUI

extension Color {
    /// App 的主色：按钮、图标、信号曲线
    static let appAccent = Color.indigo
}

/// 首页的一台电脑：图标、名字、连接状态、锁屏状态、信号
struct ComputerRow: View {
    let computer: ComputerLink

    var body: some View {
        HStack(spacing: 14) {
            PlatformIcon(computer: computer, size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(computer.name ?? "未知")
                    .font(.headline)
                    .lineLimit(1)
                ComputerStatus(computer: computer, compact: true)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if lockState != nil || autoUnlock {
                    HStack(spacing: 6) {
                        if let lockState {
                            LockPill(computer: computer, state: lockState)
                        }
                        if autoUnlock {
                            Pill("自动解锁", symbol: "bolt.fill", color: .green)
                        }
                    }
                }
                if let problem = computer.linkProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            SignalReading(rssi: rssi)
        }
        .padding(.vertical, 6)
    }

    private var lockState: UInt8? {
        computer.computerState.flatMap { $0 == ComputerState.unknown ? nil : $0 }
    }

    private var autoUnlock: Bool {
        computer.hasUnlockEnrollment && computer.automaticUnlockEnabled
    }

    /// 没连上时不显示上一次的信号，免得看起来还连着
    private var rssi: Int? {
        computer.phase == .connected ? computer.lastRSSI : nil
    }
}

/// 连接状态：圆点 + 一句话。首页用短的，详情页用长的
struct ComputerStatus: View {
    let computer: ComputerLink
    var compact = false

    var body: some View {
        switch computer.phase {
        case .connected:
            if computer.serviceMissingSince != nil {
                StatusText(compact ? "电脑端程序没在运行" : "已连接，但电脑端程序没在运行", color: .orange)
            } else if computer.subscribed {
                if computer.dormant {
                    StatusText(compact ? "已连接 · 电脑在休眠"
                               : "已连接，电脑在休眠（心跳 \(computer.announcedInterval ?? 0) 秒一次）", color: .green)
                } else {
                    StatusText("已连接", color: .green)
                }
            } else {
                StatusText(compact ? "正在订阅心跳…" : "已连接，正在订阅心跳", color: .orange)
            }
        case .connecting:
            if let at = computer.disconnectedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StatusText("断开 \(ContentView.duration(context.date.timeIntervalSince(at)))"
                               + (compact ? "" : "，等待重连"), color: .orange)
                }
            } else {
                StatusText("正在连接…", color: .orange)
            }
        case .searching:
            StatusText(compact ? "正在搜索" : "系统找不到它，正在搜索", color: .secondary)
        case .bluetoothUnavailable:
            StatusText("蓝牙不可用", color: .red)
        }
    }
}

/// 一台电脑的详情：状态、信号、靠近自动解锁、管理、诊断
struct ComputerDetailView: View {
    let manager: LinkManager
    let computer: ComputerLink
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @State private var enrollmentCode = ""
    @State private var enrollmentError: String?
    @State private var scanningEnrollment = false
    @State private var pasting = false

    var body: some View {
        List {
            header
            problemSection
            signalSection
            if showsUnlock {
                unlockSection
            }
            manageSection
            diagnosticsSection
        }
        .navigationTitle(computer.name ?? "电脑")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanningEnrollment) {
            EnrollmentScanSheet(computer: computer) { code in
                saveEnrollment(code)
            }
        }
    }

    private var showsUnlock: Bool {
        computer.platform == "darwin" || computer.platform == "win32" || computer.supportsUnlock || computer.hasUnlockEnrollment
    }

    /// 没连上时不显示上一次的信号，和首页一样
    private var rssi: Int? {
        computer.phase == .connected ? computer.lastRSSI : nil
    }

    // MARK: - 头部

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                PlatformIcon(computer: computer, size: 72)
                Text(computer.name ?? "未知")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                ComputerStatus(computer: computer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let platform = computer.platform {
                        Pill(ContentView.platformName(platform), color: .secondary)
                    }
                    if let state = computer.computerState, state != ComputerState.unknown {
                        LockPill(computer: computer, state: state)
                    }
                    if computer.hasUnlockEnrollment && computer.automaticUnlockEnabled {
                        Pill("自动解锁", symbol: "bolt.fill", color: .green)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 连接问题

    @ViewBuilder private var problemSection: some View {
        let canReconnect = !computer.isSimulated && (computer.linkProblem != nil || computer.phase == .connecting)
        if computer.linkProblem != nil || computer.protoWarning != nil || canReconnect {
            Section {
                if let problem = computer.linkProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let warning = computer.protoWarning {
                    Label(warning, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                if canReconnect {
                    Button {
                        computer.reconnect()
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    // MARK: - 信号

    private var signalSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rssi.map(String.init) ?? "—")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("dBm")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                PhoneStateBadge(state: computer.phoneState)
            }
            if !computer.samples.isEmpty {
                RSSIChart(samples: computer.samples, settings: manager.settings)
                    .frame(height: 160)
                    .padding(.vertical, 4)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let recent = computer.samples.filter { context.date.timeIntervalSince($0.time) <= 10 }.map(\.rssi)
                HStack(spacing: 0) {
                    Stat(title: "最近 10 秒中位",
                         value: recent.isEmpty ? "—" : "\(ProximityJudge.median(recent)) dBm")
                    Divider()
                    Stat(title: "距上次心跳",
                         value: computer.lastHeartbeatAt.map { String(format: "%.1f 秒", context.date.timeIntervalSince($0)) } ?? "—")
                    Divider()
                    // 电脑在每次心跳里写下一次最晚几秒后到（v1.2）：没人用电脑时放慢，锁久了休眠；没写按 1 秒
                    Stat(title: computer.dormant ? "心跳间隔（休眠）" : "心跳间隔",
                         value: "\(computer.announcedInterval ?? 1) 秒")
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("信号")
        } footer: {
            Text("「靠近 / 离开」是手机自己的判断，只作参考；人在不在由电脑结合键盘鼠标来判断。")
        }
    }

    // MARK: - 靠近自动解锁

    private var unlockSection: some View {
        Section {
            if computer.hasUnlockEnrollment {
                Toggle(isOn: Binding(
                    get: { computer.automaticUnlockEnabled },
                    set: { computer.setAutomaticUnlock($0) }
                )) {
                    Label("靠近时自动解锁", systemImage: "bolt.fill")
                }
                if computer.supportsUnlock {
                    Button {
                        computer.requestUnlock()
                    } label: {
                        Label("现在解锁这台电脑", systemImage: "lock.open.fill")
                    }
                    .disabled(!computer.canRequestUnlock)
                }
            } else {
                if !computer.supportsUnlock {
                    Text("请先在这台电脑本机设置解锁，再重新连接。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    startScanning()
                } label: {
                    Label("扫码登记", systemImage: "qrcode.viewfinder")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(computer.unlockBusy)
                pasteRow
            }
            if computer.unlockBusy {
                ProgressView("正在处理这次解锁…")
            }
            if let message = enrollmentError ?? computer.unlockStatus {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("靠近自动解锁")
        } footer: {
            Text(computer.hasUnlockEnrollment
                 ? "手机靠近、电脑请提示解锁时，自动发一次签名请求，每次提示只试一次；请求发出后连接断了，重新连上时补发一次。关掉自动解锁后，可以用上面的按钮手动解锁。"
                 : "点「扫码登记」会请电脑弹出登记窗口：在电脑上点一下确认，它才显示二维码，再用手机扫（第一次登记要在电脑上输一次登录密码）。也可以粘贴登记码。登记码只存在这部手机的钥匙串里，登记后默认靠近自动解锁。")
        }
    }

    /// 粘贴登记码：收起来，扫不了码时再展开
    private var pasteRow: some View {
        DisclosureGroup(computer.hasUnlockEnrollment ? "粘贴登记码更新" : "粘贴登记码", isExpanded: $pasting) {
            SecureField("这台电脑的登记码", text: $enrollmentCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(computer.hasUnlockEnrollment ? "更新登记" : "保存登记") {
                saveEnrollment(enrollmentCode)
            }
            .disabled(enrollmentCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || computer.unlockBusy)
        }
    }

    /// 点「扫码登记」：电脑能请就先请它弹出登记窗口（电脑上先确认再显示二维码），同时打开相机
    private func startScanning() {
        computer.requestEnrollmentCode()
        scanningEnrollment = true
    }

    private func saveEnrollment(_ code: String) {
        do {
            try computer.enrollUnlock(code)
            enrollmentCode = ""
            enrollmentError = nil
            pasting = false
        } catch {
            enrollmentError = error.localizedDescription
        }
    }

    // MARK: - 管理

    @ViewBuilder private var manageSection: some View {
        if computer.hasUnlockEnrollment || !computer.isSimulated {
            Section("管理") {
                if computer.hasUnlockEnrollment {
                    Button {
                        startScanning()
                    } label: {
                        Label("扫码更新登记", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(computer.unlockBusy)
                    pasteRow
                    Button(role: .destructive) {
                        do {
                            try computer.removeUnlockEnrollment()
                            enrollmentCode = ""
                            enrollmentError = nil
                        } catch {
                            enrollmentError = error.localizedDescription
                        }
                    } label: {
                        Label("删除解锁登记", systemImage: "minus.circle")
                    }
                    .disabled(computer.unlockBusy)
                }
                if !computer.isSimulated {
                    Button(role: .destructive) {
                        confirmForget = true
                    } label: {
                        Label("忘记这台电脑", systemImage: "trash")
                    }
                    .confirmationDialog("忘记以后不再连它，要用的话重新搜索添加", isPresented: $confirmForget,
                                        titleVisibility: .visible) {
                        Button("忘记", role: .destructive) {
                            manager.forget(computer)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("identifier", value: String(computer.savedID.uuidString.prefix(8)))
            if computer.searchingMoved {
                Text("也在找换了地址的同一台电脑：搜到带协议服务的设备就连上读电脑名，对得上就改连它。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if computer.hasUnlockEnrollment && computer.supportsUnlock {
                Toggle("测试：下次解锁请求假装断线", isOn: Binding(
                    get: { computer.simulateUnlockDrop },
                    set: { computer.setSimulateUnlockDrop($0) }
                ))
            }
        } header: {
            Text("诊断")
        } footer: {
            if computer.hasUnlockEnrollment && computer.supportsUnlock {
                Text("「假装断线」只用来测补发：打开后下一次签好名的请求不发出去，直接断开连接，只生效一次。")
            }
        }
    }
}

/// 搜索到的、还没添加的电脑。连上读到 INFO 才知道真名
struct FoundList: View {
    let manager: LinkManager
    var onAdd: () -> Void = {}

    var body: some View {
        if manager.found.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在搜索电脑…")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(manager.found) { computer in
            let added = manager.isAdded(computer)
            Button {
                manager.add(computer.id)
                onAdd()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.title3)
                        .foregroundStyle(added ? Color.secondary : Color.appAccent)
                        .frame(width: 36, height: 36)
                        .background((added ? Color.secondary : Color.appAccent).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(computer.name ?? computer.advertisedName ?? "未命名")
                            .foregroundStyle(computer.name == nil || added ? .secondary : .primary)
                        Text(detail(computer, added: added))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if computer.rssi != 0 {
                        SignalReading(rssi: computer.rssi)
                    }
                }
            }
            .disabled(added)
        }
    }

    private func detail(_ computer: FoundComputer, added: Bool) -> String {
        var parts = [String(computer.id.uuidString.prefix(8))]
        if added {
            parts.append("已经添加过同名的电脑")
        } else if computer.name == nil {
            parts.append(computer.nameFailed ? "读不到电脑名，也可以直接添加" : "正在连上读电脑名…")
        }
        return parts.joined(separator: " · ")
    }
}

/// 「添加电脑」：打开时搜索，关掉就停（还有电脑没连上时照样在找它）
struct AddComputerView: View {
    let manager: LinkManager
    @Environment(\.dismiss) private var dismiss

    static let hint = "先在电脑上运行电脑端程序（Windows：prototype/win_peer.py，Mac：prototype/mac_peer/run.sh），再点这里出现的电脑。搜到的设备会先连上读电脑名，电脑要求配对时会弹配对请求。"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FoundList(manager: manager) { dismiss() }
                } header: {
                    Text("附近的电脑")
                } footer: {
                    Text(Self.hint)
                }
            }
            .navigationTitle("添加电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .tint(.appAccent)
        .onAppear { manager.startAdding() }
        .onDisappear { manager.stopAdding() }
    }
}

// MARK: - 小部件

/// 电脑图标：Mac mini、Mac、Windows。没连上时变灰
struct PlatformIcon: View {
    let computer: ComputerLink
    var size: CGFloat = 48

    var body: some View {
        let color = computer.phase == .connected ? Color.appAccent : Color.secondary
        Image(systemName: ContentView.platformSymbol(computer.platform, name: computer.name))
            .font(.system(size: size * 0.45))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// 信号格加 dBm：-95 dBm 算 0 格，-50 dBm 以上满格
struct SignalReading: View {
    let rssi: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Image(systemName: "cellularbars", variableValue: level)
                .font(.title3)
                .foregroundStyle(rssi == nil ? Color.secondary : Color.appAccent)
            Text(rssi.map { "\($0) dBm" } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var level: Double {
        guard let rssi else { return 0 }
        return min(1, max(0, Double(rssi + 95) / 45))
    }
}

/// 小胶囊标签：系统、锁屏状态、自动解锁
struct Pill: View {
    let text: String
    let symbol: String?
    let color: Color

    init(_ text: String, symbol: String? = nil, color: Color) {
        self.text = text
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// 电脑的锁屏状态（心跳里的电脑状态）
struct LockPill: View {
    let computer: ComputerLink
    let state: UInt8

    var body: some View {
        switch state {
        case ComputerState.unlocked:
            Pill("未锁屏", symbol: "lock.open.fill", color: .secondary)
        case ComputerState.locked:
            Pill("已锁屏", symbol: "lock.fill", color: .secondary)
        case ComputerState.promptUnlock:
            Pill("等你解锁" + (computer.promptID.map { " #\($0)" } ?? ""), symbol: "lock.fill", color: .orange)
        default:
            Pill(ComputerState.label(state), color: .secondary)
        }
    }
}

struct StatusText: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

/// 信号区下面的一格数字
private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 手机自己的判断（仅参考）
private struct PhoneStateBadge: View {
    let state: PhoneState

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(state.label)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
            Text("手机判断，仅参考")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch state {
        case .near: .green
        case .away: .orange
        case .undetermined: .secondary
        }
    }
}

/// 最近 3 分钟的信号曲线，虚线是手机判断用的「靠近」「离开」阈值
private struct RSSIChart: View {
    let samples: [RSSISample]
    let settings: JudgeSettings

    var body: some View {
        Chart {
            ForEach(samples, id: \.time) { s in
                AreaMark(x: .value("时间", s.time), yStart: .value("下限", -100), yEnd: .value("dBm", s.rssi))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.appAccent.opacity(0.28), Color.appAccent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", s.time), y: .value("dBm", s.rssi))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.appAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("靠近", settings.nearDbm))
                .foregroundStyle(.green.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("靠近").font(.caption2).foregroundStyle(.green)
                }
            RuleMark(y: .value("离开", settings.awayDbm))
                .foregroundStyle(.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .bottom, alignment: .leading) {
                    Text("离开").font(.caption2).foregroundStyle(.orange)
                }
        }
        .chartYScale(domain: -100 ... -30)
        .chartYAxis {
            AxisMarks(values: [-100, -80, -60, -40]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
    }
}
