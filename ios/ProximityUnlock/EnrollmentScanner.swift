import AVFoundation
import SwiftUI
import VisionKit

/// 扫电脑上显示的登记二维码。二维码里就是登记码本身，和手动粘贴的一样；
/// 只有认得出是登记码的才交回去，扫到别的二维码不理、接着扫。登记码不显示、不写日志。
/// 上面一行是电脑对「请电脑显示登记码」的回复；电脑端太旧没法请时，提示去电脑上打开登记窗口
struct EnrollmentScanSheet: View {
    let computer: ComputerLink
    let onCode: (String) -> Void

    static let manualHint = "这台电脑的电脑端还不能自动弹窗：在电脑上打开登记窗口（Mac：MacPeer --setup-unlock；Windows：manage.ps1 -Action Export）"
    @Environment(\.dismiss) private var dismiss
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hint = "对准电脑上显示的登记二维码"

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    unavailable("这台手机不支持扫码，请粘贴登记码。")
                } else if camera == .denied || camera == .restricted {
                    unavailable("没有相机权限。去「设置 → 靠近解锁」里打开相机，或者粘贴登记码。")
                } else if camera == .authorized {
                    QRScanner { payload in
                        guard (try? UnlockEnrollment.parse(payload)) != nil else {
                            hint = "扫到的不是登记码，请扫电脑上登记窗口里的二维码"
                            return false
                        }
                        onCode(payload)
                        dismiss()
                        return true
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text(hint)
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 32)
                    }
                } else {
                    ProgressView("正在请求相机权限…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                // 电脑那边的情况：扫不了码时电脑上的窗口也有登记码可以复制粘贴，所以哪种情况都显示
                Label(computer.enrollRequestStatus ?? Self.manualHint, systemImage: "desktopcomputer")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            .navigationTitle("扫码登记 \(computer.name ?? "这台电脑")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                guard camera == .notDetermined else { return }
                _ = await AVCaptureDevice.requestAccess(for: .video)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func unavailable(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
    }
}

/// VisionKit 的扫码界面。界面显示出来以后才能开始扫，所以包一层，在 viewDidAppear 里开始
private struct QRScanner: UIViewControllerRepresentable {
    /// 返回 true 表示收下了，不再扫
    let onPayload: (String) -> Bool

    func makeUIViewController(context: Context) -> Host {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return Host(scanner: scanner)
    }

    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.onPayload = onPayload
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Bool
        private var done = false

        init(onPayload: @escaping (String) -> Bool) { self.onPayload = onPayload }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in addedItems {
                guard let payload = code.payloadStringValue else { continue }
                if onPayload(payload) {
                    done = true
                    scanner.stopScanning()
                    return
                }
            }
        }
    }

    final class Host: UIViewController {
        let scanner: DataScannerViewController

        init(scanner: DataScannerViewController) {
            self.scanner = scanner
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            try? scanner.startScanning()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            scanner.stopScanning()
        }
    }
}
