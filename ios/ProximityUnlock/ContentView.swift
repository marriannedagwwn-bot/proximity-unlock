import CoreBluetooth
import SwiftUI

/// 首页：电脑卡片，和要用户处理的提醒（蓝牙、通知）。
/// 测试通知、记录、iBeacon、位置标记、判断参数这些测试排查用的，在右上角「工具与记录」里
struct ContentView: View {
    let manager: LinkManager
    @State private var adding = false
    @State private var forgetting: ComputerLink?

    var body: some View {
        NavigationStack {
            List {
                if manager.isSimulated {
                    Label("模拟器里没有蓝牙，下面两台电脑和数据都是假的", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                alertsSection
                computersSection
            }
            .navigationTitle("靠近解锁")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canAdd {
                        Button { adding = true } label: {
                            Label("添加电脑", systemImage: "plus")
                        }
                    }
                    NavigationLink {
                        ToolsView(manager: manager)
                    } label: {
                        Label("工具与记录", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $adding) {
                AddComputerView(manager: manager)
            }
            .confirmationDialog("忘记以后不再连它，要用的话重新搜索添加", isPresented: Binding {
                forgetting != nil
            } set: { shown in
                if !shown { forgetting = nil }
            }, titleVisibility: .visible, presenting: forgetting) { computer in
                Button("忘记「\(computer.name ?? "未知")」", role: .destructive) { manager.forget(computer) }
            }
        }
        .tint(.appAccent)
    }

    /// 已经有电脑时从右上角加；一台都没有时首页直接是搜索列表
    private var canAdd: Bool {
        !manager.isSimulated && manager.bluetoothState == .poweredOn && !manager.computers.isEmpty
    }

    // MARK: - 提醒

    /// 要用户自己处理的事，没事就不显示
    @ViewBuilder private var alertsSection: some View {
        let bluetoothDown = !manager.isSimulated && manager.bluetoothState != .poweredOn && manager.bluetoothState != .unknown
        let notificationsOff = manager.notificationStatus == .denied
        if bluetoothDown || notificationsOff {
            Section {
                if bluetoothDown {
                    AlertRow(title: "蓝牙\(manager.bluetoothState.label)",
                             symbol: "antenna.radiowaves.left.and.right.slash",
                             detail: manager.bluetoothState == .unauthorized
                                ? "去「设置 → 隐私与安全性 → 蓝牙」里打开「靠近解锁」" : nil)
                }
                if notificationsOff {
                    AlertRow(title: "通知被关掉了", symbol: "bell.slash.fill",
                             detail: "电脑锁屏后你回来时手机不会提示。去「设置 → 通知 → 靠近解锁」里打开。")
                }
            }
        }
    }

    // MARK: - 电脑

    @ViewBuilder private var computersSection: some View {
        if manager.computers.isEmpty {
            Section {
                if manager.bluetoothState == .poweredOn {
                    FoundList(manager: manager)
                }
            } header: {
                Text("添加电脑")
            } footer: {
                if !manager.isSimulated {
                    Text(AddComputerView.hint)
                }
            }
        } else {
            Section {
                ForEach(manager.computers) { computer in
                    NavigationLink {
                        ComputerDetailView(manager: manager, computer: computer)
                    } label: {
                        ComputerRow(computer: computer)
                    }
                    .swipeActions {
                        if !computer.isSimulated {
                            Button("忘记") { forgetting = computer }
                                .tint(.red)
                        }
                    }
                }
            } header: {
                Text("我的电脑")
            } footer: {
                if !manager.isSimulated {
                    Text("点进去看信号、登记解锁；左滑可以忘记。锁屏、切到别的 App 都不影响后台连接，但别在多任务界面把它划掉。")
                }
            }
        }
    }

    // MARK: - 格式

    static func platformName(_ platform: String) -> String {
        switch platform {
        case "win32": "Windows"
        case "darwin": "Mac"
        case "simulator": "模拟"
        default: platform
        }
    }

    /// 电脑图标：Mac mini、MacBook、其他 Mac、Windows
    static func platformSymbol(_ platform: String?, name: String?) -> String {
        let name = (name ?? "").lowercased()
        switch platform {
        case "darwin":
            if name.contains("mini") { return "macmini" }
            if name.contains("macbook") { return "laptopcomputer" }
            return "desktopcomputer"
        case "win32":
            return "pc"
        default:
            return "desktopcomputer"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s) 秒" : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func segmentSummary(_ values: [Int]) -> String {
        guard let lo = values.min(), let hi = values.max() else { return "还没有数据" }
        return "\(values.count) 次 · 中位 \(ProximityJudge.median(values)) · \(lo) 到 \(hi)"
    }
}

/// 首页顶上要用户处理的一条提醒
private struct AlertRow: View {
    let title: String
    let symbol: String
    let detail: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.orange)
        }
    }
}
