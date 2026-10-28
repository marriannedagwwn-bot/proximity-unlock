// swift-tools-version:5.9
import PackageDescription

// Mac 电脑端原型。判断逻辑（PeerCore）和蓝牙、系统接口（mac_peer）分开，判断逻辑能用假数据测。
// 编译、运行用 build.sh / run.sh，见 README.md。
let package = Package(
    name: "mac_peer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PeerCore"),
        .target(name: "MacHost", dependencies: ["PeerCore"]),
        .executableTarget(name: "mac_peer", dependencies: ["PeerCore", "MacHost"]),
        .testTarget(name: "PeerCoreTests", dependencies: ["PeerCore"]),
        .testTarget(name: "MacHostTests", dependencies: ["MacHost"]),
    ]
)
