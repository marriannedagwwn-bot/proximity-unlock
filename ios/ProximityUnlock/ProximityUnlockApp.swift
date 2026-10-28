import SwiftUI
import UIKit

@main
struct ProximityUnlockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(manager: LinkManager.shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 系统为了蓝牙、iBeacon 区域事件在后台拉起 App 时不一定会建界面，所以在这里就建好 central 和 CLLocationManager
        LinkManager.shared.start(launchOptions: launchOptions)
        return true
    }
}
