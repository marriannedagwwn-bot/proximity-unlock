# 靠近解锁（Proximity Unlock）

拿着 iPhone 走到电脑前，电脑自己解锁；走开，电脑自己锁屏。支持 Windows 和 macOS，一部 iPhone 可以同时连几台电脑。

> **English**: Unlock your Windows PC or Mac when your iPhone comes near, and lock it when you walk away. The iPhone app keeps a Bluetooth LE connection to each computer and reports signal strength; the computer decides whether you are there by combining that signal with keyboard and mouse idle time. Unlock requests are signed with a key enrolled offline (scan a QR code on the computer). This is a working prototype; see `docs/protocol.md` for the protocol and the rules (in Chinese). MIT licensed.

## 能做什么

- **走开自动锁屏**：手机信号显示走远了（或者连接断了），并且电脑一段时间没人碰键盘鼠标，才锁屏，人在打字时不会误锁。
- **回来自动解锁**：电脑锁着、手机走远过又回来，信号比走远时明显变强，电脑就请手机解锁。登记过的手机自动发一次签名请求，电脑核对后解锁：
  - Mac：用辅助功能把钥匙串里存的登录密码填进登录窗口；
  - Windows：自带的 Credential Provider。

  没登记的电脑只在手机上弹一条通知提示。
- **扫码登记**：在 App 里点「扫码登记」，电脑上先弹确认窗口，点了才显示登记二维码；手机扫码保存后，电脑上的窗口自己关。
- 同时连多台电脑，每台各自判断、各自提示；电脑没人用时心跳放慢、锁久了休眠，省电。

## 怎么工作

- iPhone App 当蓝牙中心，电脑当外设（GATT 服务端）。电脑每秒发一次心跳，手机收到就读一次这条连接的信号强度（RSSI）写回去。
- **人在不在由电脑判断**：手机信号加上电脑键盘鼠标空闲多久。只看信号分不清「手机揣兜里坐在电脑前」和「站在门口」，实测只差 5 dB 左右。
- 解锁请求和信号报告都用登记时导入手机的 32 字节随机密钥做 HMAC 签名，并绑定电脑这次启动的随机数，旧请求重放不了。密钥只通过电脑屏幕上的二维码（或复制粘贴）导入手机，不经过蓝牙。
- 协议和判断规则见 [`docs/protocol.md`](docs/protocol.md)。

## 安装包

到 [Releases](../../releases) 下载：

| 平台 | 文件 | 说明 |
|---|---|---|
| iPhone | `ProximityUnlock-<版本>-unsigned.ipa` | **没有签名**，用你自己的 Apple ID 或证书签了再装（AltStore、Sideloadly、Xcode 等）。需要 iOS 17 以上，要给蓝牙、通知、相机（扫码）权限。 |
| macOS | `MacPeer-<版本>-macOS.zip` | Apple 芯片和 Intel 通用，需要 macOS 13 以上。**没有经过 Apple 公证**，第一次打开时系统会拦，去「系统设置 → 隐私与安全性」里点「仍要打开」。要给蓝牙、辅助功能权限。用法见 [`prototype/mac_peer/README.md`](prototype/mac_peer/README.md)。 |
| Windows | 稍后提供 | 现在可以从源码运行，见下面。 |

## 从源码编译和运行

- **iPhone App**：[`ios/README.md`](ios/README.md)（Xcode 16 以上）。
- **Mac 电脑端**：[`prototype/mac_peer/README.md`](prototype/mac_peer/README.md)（SwiftPM，`build.sh` 打包成 `MacPeer.app`，`autostart.sh install` 装成登录自启）。
- **Windows 电脑端**：`prototype/win_peer.py`（Python 3.12，WinRT 蓝牙），`prototype/install_autostart.ps1` 装成登录自启；自动解锁用的 Credential Provider 和支持范围见 [`prototype/windows_unlock/README.md`](prototype/windows_unlock/README.md)。
- **蓝牙信号实测工具**：[`docs/rssi_probe.md`](docs/rssi_probe.md)。

## 安全须知

- 这是原型。登记以后，拿着你手机的人走到电脑前，电脑就可能自动解锁。不想要的话，在 App 里关掉这台电脑的「靠近时自动解锁」或者删除登记。
- Mac 的登录密码只存在本机钥匙串（不同步到 iCloud）；Windows 的凭据用 DPAPI 存在本机。手机只存随机密钥，拿不到电脑密码。
- 登记二维码就是解锁这台电脑的密钥，别让别人拍到；换手机或怀疑泄露时，在电脑上重新登记，旧密钥就作废了。

## 目录

| 路径 | 内容 |
|---|---|
| `ios/` | iPhone App（SwiftUI + CoreBluetooth） |
| `prototype/mac_peer/` | Mac 电脑端（Swift + CoreBluetooth） |
| `prototype/win_peer.py` 等 | Windows 电脑端（Python + WinRT） |
| `prototype/windows_unlock/` | Windows 自动解锁组件（C++ Credential Provider 和登记工具） |
| `docs/protocol.md` | 蓝牙协议和判断规则 |
| `rssi_probe.py`、`link_analyze.py` | 信号实测和日志分析工具 |
| `tests/` | Windows 电脑端的单元测试 |

## 许可

[MIT](LICENSE)
