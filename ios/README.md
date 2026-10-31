# iPhone App 原型 v0

按 `docs/protocol.md` 连接电脑：订阅心跳，每收到一次心跳就读一次连接的 RSSI，再写回 REPORT。
所有事件都记到手机上的 CSV，可以导出来和电脑端的日志对照。

## 装到 iPhone（免费 Apple ID）

1. 打开工程：`open ios/ProximityUnlock.xcodeproj`
2. Xcode → 设置 → Accounts，加上 Apple ID。
3. 左边选 ProximityUnlock 工程 → TARGETS 里的 ProximityUnlock → Signing & Capabilities → Team 选自己的（Personal Team）。
   提示 Bundle ID 被占用时，把 `io.github.marriannedagwwn.ProximityUnlock` 改成别的。
4. iPhone 用线连上 Mac。iPhone 上打开「设置 → 隐私与安全性 → 开发者模式」，第一次要重启手机。
5. Xcode 顶部选这台 iPhone，按 ⌘R。第一次装完要在 iPhone「设置 → 通用 → VPN 与设备管理」里信任自己的开发者证书。
6. 免费签名 7 天过期，过期后 App 打不开，连上 Mac 再按一次 ⌘R 就行。

## 用法

1. 先在电脑上运行电脑端程序（Windows：`python prototype\win_peer.py`；Mac：`prototype/mac_peer/run.sh`）。
2. 打开 App，首页「添加电脑」里会出现正在广播的电脑，点它。App 会记住这台电脑，以后自动重连。
   - 列表里的名字是连上读 INFO 读来的（广播包放不下名字），读到之前先显示广播里的名字或「未命名」。电脑要求配对时会弹配对请求。
3. 要同时用几台电脑（比如 Windows 和 Mac）：点右上角的「+」，再选一台。每台各自连接、各自报信号、各自弹通知，不用再忘记这台、改选那台。
   - 首页「我的电脑」每台一张卡片：连接状态和信号、有没有开自动解锁，右边是锁按钮（显示锁没锁，点了解锁或锁屏，见下面「首页锁按钮」）；点进去看信号曲线、登记解锁、「重新连接」；左滑或在详情页「管理」里「忘记」。
   - 旧版本记住的那一台电脑升级后自动留着。
4. 状态显示「已连接」后就可以锁屏放兜里。锁屏、切到别的 App 都不影响；**别在多任务界面把它划掉**，划掉后系统不会再在后台唤醒它。
5. 测试、排查用的东西都在右上角「工具与记录」里：测试通知、本次记录（导出 CSV、新建记录）、iBeacon（实验）、位置标记、手机判断参数。
6. 测各个位置的信号：在「工具与记录」→「位置标记」里先点位置，再锁屏、带着手机走过去，待 90 秒左右。标签和 `rssi_probe.py` 的一样，每台电脑的信号分开统计。
7. 「工具与记录」里的「导出 CSV」用分享发到电脑；也能在「文件」App →「我的 iPhone」→「靠近解锁」里找到所有记录。

分析：`python link_analyze.py phone_….csv [peer_….csv]`（仓库根目录），按 `docs/protocol.md` 里 v0 的 4 个问题输出，两个文件按时间对齐。
连着几台电脑时，几台电脑的事件在同一个手机 CSV 里，`device` 列是「电脑名（identifier 前 8 位）」；分析时加 `--device DESKTOP` 或 `--device Mac` 选一台。

电脑锁屏后人回来时（心跳里电脑状态 3），App 弹一条本地通知「电脑名 已锁屏，是你回来了吗？」，电脑解锁或人又走远后自动撤掉。每台电脑一条，只撤那台的。第一次打开 App 时要允许通知；在后台也能弹，不用打开 App。

### Windows / Mac 靠近自动解锁

先在对应电脑本机设置中保存登录凭据并生成离线登记码，再到手机上这台电脑的详情 →「靠近自动解锁」，点「扫码登记」扫电脑登记窗口里的二维码（第一次要允许相机），或者粘贴完整登记码保存。点「扫码登记」时 App 会顺着连接请电脑弹出登记窗口（`docs/protocol.md`「手机请求显示登记码」）：电脑上先问一句，点了「显示二维码」（第一次登记是「登记…」，要输一次登录密码）才出码；电脑锁着屏时手机上会提示先解锁；电脑端还没更新的，扫码页上提示去电脑上自己打开登记窗口。二维码里就是登记码本身，扫到别的二维码 App 不理、接着扫。保存以后 App 给连着的电脑发一次登记确认（`docs/protocol.md`「登记确认」），电脑的登记窗口收到就自己关（Mac 第一次登记时要手动点「完成」）。**登记后默认靠近自动解锁，无需逐次手机确认**；可关闭自动开关改用手动确认。电脑未声明受支持能力，或本连接的认证 REPORT 尚未收到成功回复时，不提供可用解锁动作。

App 明确识别 `platform: "darwin"` + `unlock: "ax-hmac-v3"` 和 `platform: "win32"` + `unlock: "win-hmac-v3"` 两组能力，不能混用或仅靠协议版本推断。两端复用同样的 v3 认证 REPORT、CHALLENGE / UNLOCK 字节格式和固定 HMAC 向量。手机对每条报告加入随机数及签名；电脑拒绝无签名、过期或重放的报告。重新连接或电脑重新发布认证服务时会重读 INFO 的报告会话随机数；传输容量不足时暂停自动解锁。

手机只保存 32 字节随机密钥，不接触电脑登录密码。密钥存 `AfterFirstUnlockThisDeviceOnly` 钥匙串，手机重启后必须先解锁一次。每台电脑的 `(reportNonce, promptID)` 只自动尝试一次，去重标记持久保存，重连或 App 重启也不重试；电脑新进程的同编号可再次尝试。失败、断连或超时不自动重试；请求已经发出时断连，界面只说结果尚未确认。已有 Mac 钥匙串登记在升级后保留。

**首页锁按钮**：每台电脑右边一个圆按钮，图标和下面的小字是电脑现在锁没锁（等你解锁时是橙色）；锁着时点一下解锁，没锁时点一下锁屏，都不要 Face ID，结果在卡片上显示几秒。电脑没在请提示时也能手动解锁、能锁屏，要电脑端支持（INFO 里 `manual`，见 `docs/protocol.md`「手动锁屏、解锁」，Mac 和 Windows 电脑端 0.1.2 起都支持）；不支持的电脑只在请提示时能点。详情页「靠近自动解锁」里也有「现在解锁这台电脑」「锁定这台电脑」。模拟器里点锁按钮 1 秒后假装成功，假电脑保持那个状态 20 秒。

详情页可删除登记或关闭自动；忘记电脑会删除相应钥匙串登记。密钥不通过蓝牙登记，也不要发送到聊天、日志或共享文档中。Mac 的一次性授权、登记和测试边界见 `../prototype/mac_peer/README.md`；Windows 的组件、本机登记和验收边界见 `../prototype/windows_unlock/README.md`。

iOS App 只能在 Mac 上签名、构建和安装。改了解锁相关的代码以后，先运行 `bash ios/test-unlock-codec.sh` 检查两组能力白名单、协议向量和去重身份，再按下文命令构建并安装 App，最后在手机锁屏后台验证 Windows / Mac 整条链路；源码检查不能代替真机验收。

电脑没人用、手机离得远时心跳会放慢到 3 秒一次，再久就休眠成 30 秒一次（`docs/protocol.md`「心跳快慢和休眠」）。电脑每次心跳都写明下一次最晚几秒后到，App 的看门狗跟着放宽；电脑详情里「心跳间隔」显示它，休眠时首页写「电脑在休眠」。

「工具与记录」→「iBeacon 唤醒（实验）」：电脑发 iBeacon 时，App 被划掉或手机重启后走到电脑附近，系统也会把 App 拉起来（见 `docs/protocol.md`「用 iBeacon 拉起 App（实验）」）。在区域里点亮手机屏幕、或者走进区域时，App 对休眠的电脑主动报一次信号，电脑马上恢复每秒一次；不在区域里（出门了）时 App 在后台不搜索没连上的电脑。要在「设置 → 隐私与安全性 → 定位服务 → 靠近解锁」里选「始终」、打开「精确位置」（App 里的按钮只能先要到「使用期间」）。App 在前台时显示收到的 iBeacon 和信号；「区域事件发通知」开着时，进出区域各弹一条测试通知，写着 App 是不是刚被系统拉起来的。

「工具与记录」→「手机判断参数」里的阈值只决定写进 REPORT 的手机状态（靠近 / 离开），只作参考：人在不在改由电脑结合键盘鼠标活动来判断（见 `docs/protocol.md`）。靠近的默认阈值临时放宽到 -76；以前存过 -70 的，升级后自动改成 -76，自己调过别的值的不动。

## 用买来的证书签名（命令行）

有付费开发者账号或 Ad Hoc 证书时，可以从命令行编译、安装（免费 Apple ID 签的 7 天就过期）。
签名设置写在 `ios/Signing.local.xcconfig`，不进仓库（每台机器、每个证书都不一样）。证书要导入「登录」钥匙串，描述文件双击安装。

```
xcodebuild -project ios/ProximityUnlock.xcodeproj -scheme ProximityUnlock -configuration Release -sdk iphoneos -xcconfig ios/Signing.local.xcconfig -derivedDataPath /tmp/pu-device build
xcrun devicectl device install app --device <设备 identifier> /tmp/pu-device/Build/Products/Release-iphoneos/ProximityUnlock.app
```

设备 identifier 用 `xcrun devicectl list devices` 查。下面命令里的 Bundle ID 是 `Signing.local.xcconfig` 里的 `PRODUCT_BUNDLE_IDENTIFIER`（Ad Hoc 描述文件的那个），不是工程里写的 `io.github.marriannedagwwn.ProximityUnlock`，用错了拷日志会报 `ContainerLookupErrorDomain error -1`。当前日志的文件名记在 App 设置里，可以先拷出 `Library/Preferences/<Bundle ID>.plist`，看 `log.file`。

`-derivedDataPath` 不要放在仓库里：仓库在开着 iCloud 同步的文件夹（比如桌面）里时，编译产物会被加上扩展属性，签名时报 `resource fork, Finder information, or similar detritus not allowed`。

安装会结束正在运行的旧 App，系统一般马上会因为蓝牙状态恢复把新版拉起来；保险起见装完再启动一次：

```
xcrun devicectl device process launch --device <设备 identifier> <Bundle ID>
```

App 每次启动在 CSV 里记 `app_launch` 和 `settings`（当时用的判断阈值）。Ad Hoc 证书装的 App 不能用 Xcode 调试，看运行情况靠 App 自己的 CSV：

```
xcrun devicectl device copy from --device <设备 identifier> --domain-type appDataContainer --domain-identifier <Bundle ID> --source Documents/<文件名>.csv --destination .
```

## 模拟器

模拟器没有蓝牙。在模拟器里运行时 App 用两台假电脑（`DESKTOP-SIM`、`模拟的Mac mini`）各自每秒发心跳，锁屏周期不一样长（40 秒、24 秒一轮），用来看界面、每台电脑各弹各撤的通知和 CSV 格式，数据全是假的。添加、忘记电脑在模拟器里试不了。

## 文件

| 文件 | 内容 |
|---|---|
| `ProximityUnlock/Protocol.swift` | UUID 和三个特征值的字节格式 |
| `ProximityUnlock/LinkManager.swift` | 管 central 和记住的几台电脑：搜索、添加和忘记、连上读 INFO 看名字和核对换了地址的电脑、后台状态恢复、日志 |
| `ProximityUnlock/ComputerLink.swift` | 一台电脑的连接：连接、断开重连、心跳 → RSSI → REPORT、看门狗（按心跳宣布的间隔放宽）、等服务回来、休眠时主动报告 |
| `ProximityUnlock/ProximityJudge.swift` | 手机判断靠近还是离开 |
| `ProximityUnlock/UnlockPrompter.swift` | 电脑请手机提示解锁时发本地通知、撤掉通知 |
| `ProximityUnlock/UnlockAuthorization.swift` | 离线登记码、钥匙串、HMAC 编码和每提示一次的自动尝试元数据 |
| `ProximityUnlock/BeaconWatcher.swift` | iBeacon 区域监测（实验）：App 被划掉、手机重启后走到电脑附近也能被系统拉起来；前台测距显示信号 |
| `ProximityUnlock/EventLog.swift` | 写 CSV |
| `ProximityUnlock/ContentView.swift` | 首页：要处理的提醒（蓝牙、通知）和电脑卡片 |
| `ProximityUnlock/ToolsView.swift` | 「工具与记录」：测试通知、本次记录、iBeacon（实验）、位置标记、判断参数 |
| `ProximityUnlock/ComputerViews.swift` | 电脑卡片（右边锁按钮 `LockButton`）、详情页（状态、信号曲线、靠近自动解锁、管理、诊断）、添加电脑，主色 `Color.appAccent`（靛蓝） |
| `ProximityUnlock/EnrollmentScanner.swift` | 扫码登记：VisionKit 扫二维码，只收认得出的登记码 |
| `ProximityUnlock/Assets.xcassets` | App 图标（`make-icon.swift` 画的） |
| `Info.plist` | 蓝牙、定位、相机权限说明，后台蓝牙（`bluetooth-central`），在「文件」App 里显示记录 |

工程用的是 Xcode 16 起的文件夹同步：往 `ProximityUnlock/` 里加 Swift 文件不用改工程文件。
