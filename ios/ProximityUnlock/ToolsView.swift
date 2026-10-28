import CoreLocation
import SwiftUI

/// 「工具与记录」：测试通知、本次记录、iBeacon（实验）、位置标记、手机判断参数。
/// 都是测试、排查时用的，平时不用看，所以不放首页
struct ToolsView: View {
    let manager: LinkManager
    @State private var confirmNewLog = false

    var body: some View {
        List {
            promptSection
            recordSection
            beaconSection
            placeSection
            settingsSection
        }
        .navigationTitle("工具与记录")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 解锁提示

    private var promptSection: some View {
        Section {
            if manager.notificationStatus == .denied {
                Text("通知被关掉了，电脑锁屏后你回来时手机不会提示。去「设置 → 通知 → 靠近解锁」里打开。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                manager.sendTestPrompt()
            } label: {
                Label("5 秒后发一条测试通知", systemImage: "bell.badge")
            }
        } header: {
            Text("解锁提示")
        } footer: {
            Text("电脑锁屏后你回来时，那台电脑弹一条通知；它解锁或你又走远后只撤它那一条。")
        }
    }

    // MARK: - 记录

    private var recordSection: some View {
        Section {
            LabeledContent("开始于", value: manager.logStartedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("心跳") {
                Text("\(manager.stats.heartbeats) 次"
                     + (manager.stats.missed > 0 ? "，漏 \(manager.stats.missed) 次" : "")
                     + (manager.stats.skipped > 0 ? "，跳过 \(manager.stats.skipped) 次" : ""))
                    .monospacedDigit()
            }
            LabeledContent("断开") {
                Text("\(manager.stats.disconnects) 次"
                     + (manager.stats.lastReconnectSeconds.map { String(format: "，上次 %.1f 秒后重连", $0) } ?? ""))
                    .monospacedDigit()
            }
            if manager.stats.rssiFailed + manager.stats.writeErrors + manager.stats.seqResets > 0 {
                LabeledContent("异常") {
                    Text("读信号失败 \(manager.stats.rssiFailed) · 写失败 \(manager.stats.writeErrors) · seq 重置 \(manager.stats.seqResets)")
                        .monospacedDigit()
                }
            }
            ShareLink(item: manager.logURL) {
                Label("导出 CSV", systemImage: "square.and.arrow.up")
            }
            Button {
                confirmNewLog = true
            } label: {
                Label("新建记录", systemImage: "doc.badge.plus")
            }
            .confirmationDialog("之后的事件写进新文件，旧文件保留", isPresented: $confirmNewLog,
                                titleVisibility: .visible) {
                Button("新建记录") { manager.newLog() }
            }
        } header: {
            Text("本次记录")
        } footer: {
            Text("\(manager.logURL.lastPathComponent)\n心跳和断开是所有电脑合计；CSV 的 device 列分得出是哪台。也可以在「文件」App →「我的 iPhone」→「靠近解锁」里找到所有记录。")
        }
    }

    // MARK: - iBeacon（实验）

    @ViewBuilder private var beaconSection: some View {
        let beacon = manager.beacon
        Section {
            if !beacon.available {
                Text("这台设备不支持 iBeacon 区域监测（模拟器里也没有）")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("定位权限", value: BeaconWatcher.label(beacon.authorization) + (beacon.precise ? "" : "，模糊位置"))
                if !beacon.precise {
                    Text("「精确位置」关着时测不到 iBeacon。去「设置 → 隐私与安全性 → 定位服务 → 靠近解锁」里打开「精确位置」。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if beacon.authorization != .authorizedAlways {
                    Button(beacon.authorization == .notDetermined ? "允许定位"
                           : beacon.authorization == .authorizedWhenInUse ? "改成「始终」" : "去设置里打开") {
                        beacon.requestAlways()
                    }
                    Text("要选「始终」，系统才会在 App 没运行时把它拉起来。系统没给「始终」的选项时，去「设置 → 隐私与安全性 → 定位服务 → 靠近解锁」里改。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("区域") {
                    Text(BeaconWatcher.label(beacon.regionState)
                         + (beacon.regionSince.map { " · " + $0.formatted(date: .omitted, time: .standard) + " 起" } ?? ""))
                }
                if beacon.authorization == .authorizedAlways || beacon.authorization == .authorizedWhenInUse {
                    if beacon.seen.isEmpty {
                        LabeledContent("收到的 iBeacon", value: "没有")
                    }
                    ForEach(beacon.seen) { b in
                        LabeledContent("iBeacon \(b.id)") {
                            Text("\(b.rssi) dBm · \(BeaconWatcher.label(b.proximity))").monospacedDigit()
                        }
                    }
                }
                Toggle("区域事件发通知（测试用）", isOn: Binding {
                    beacon.notifyEvents
                } set: {
                    beacon.setNotifyEvents($0)
                })
            }
        } header: {
            Text("iBeacon 唤醒（实验）")
        } footer: {
            Text("电脑发 iBeacon 时，App 被划掉或手机重启（解锁过一次）以后，走到电脑附近系统也会把它拉起来，拉起来以后照常连电脑。信号只在 App 打开时测；major.minor 用来区分是哪台电脑。")
        }
    }

    // MARK: - 位置标记

    private var placeSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Place.all) { place in
                    let selected = manager.place == place
                    Button { manager.mark(place) } label: {
                        Text(place.name).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(selected ? .appAccent : .secondary)
                    .fontWeight(selected ? .semibold : .regular)
                }
            }
            .padding(.vertical, 4)
            if let place = manager.place, let since = manager.placeSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("当前", value: "\(place.name) · 已 \(ContentView.duration(context.date.timeIntervalSince(since)))")
                }
                if place.cls != "skip" {
                    ForEach(manager.computers) { computer in
                        LabeledContent((manager.placeRestored ? "这一段（重启后）" : "这一段") + " · " + (computer.name ?? "未知")) {
                            Text(ContentView.segmentSummary(manager.placeRSSI[computer.key] ?? [])).monospacedDigit()
                        }
                    }
                }
            }
        } header: {
            Text("位置标记")
        } footer: {
            Text("先点位置，再锁屏、带着手机走过去，待 90 秒左右。标签记进 CSV，和 rssi_probe.py 的标签一样；每台电脑的信号分开统计。")
        }
    }

    // MARK: - 判断参数

    private var settingsSection: some View {
        Section {
            Stepper(value: setting(\.nearDbm), in: (manager.settings.awayDbm + 1)...(-30)) {
                LabeledContent("靠近", value: "中位 ≥ \(manager.settings.nearDbm) dBm")
            }
            Stepper(value: setting(\.awayDbm), in: -100...(manager.settings.nearDbm - 1)) {
                LabeledContent("离开", value: "中位 < \(manager.settings.awayDbm) dBm")
            }
            Stepper(value: setting(\.awaySeconds), in: 0...60) {
                LabeledContent("离开要持续", value: "\(manager.settings.awaySeconds) 秒")
            }
            Stepper(value: setting(\.window), in: 1...20) {
                LabeledContent("中位取最近", value: "\(manager.settings.window) 次")
            }
        } header: {
            Text("手机判断参数（仅参考）")
        } footer: {
            Text("人在不在改由电脑判断：电脑结合键盘鼠标有没有人在用，再看这里报过去的信号。手机自己的判断只写进 REPORT 作参考，揣兜里坐着和走开只差 8 到 10 dB，单靠信号分不清。断开连接直接算离开。每台电脑各判各的，参数共用。")
        }
    }

    private func setting(_ keyPath: WritableKeyPath<JudgeSettings, Int>) -> Binding<Int> {
        Binding {
            manager.settings[keyPath: keyPath]
        } set: { value in
            var s = manager.settings
            s[keyPath: keyPath] = value
            manager.updateSettings(s)
        }
    }
}
