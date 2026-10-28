# Mac 电脑端原型

和 `prototype/win_peer.py` 一样：当蓝牙外设等 iPhone 来连接，每秒发心跳（没人用电脑、手机在远处时放慢到 3 秒，再久就休眠成 30 秒），收手机报的信号；
结合键盘鼠标活动判断人在不在，离开就锁屏，回来时请手机提示解锁。规则和日志格式见 `docs/protocol.md`。

明确登记后也支持 Mac 自动解锁：手机靠近时发送一次签名请求，Mac 将本机钥匙串中的密码填入 loginwindow 的安全密码框，确认系统解锁后才报成功。没有登记时仍只点亮屏幕。

## 启用手机靠近自动解锁

1. 运行 `prototype/mac_peer/build.sh`，记下最后输出的 `MacPeer.app` 路径。
2. 用同一个 App 打开本机设置：`open -n -a /实际路径/MacPeer.app --args --setup-unlock`。首次先按界面提示，在系统设置中给这份 MacPeer 辅助功能和发送系统事件权限，再重新打开设置。
3. 在本机安全输入框中填写当前账户的 Mac 登录密码。程序先本机验证，再存到不同步的钥匙串；不会把密码写进日志、命令行、文件或手机。
4. 在 iPhone App → 这台 Mac 的详情 →「靠近自动解锁」里点「扫码登记」，扫本机窗口里的二维码；也可以手动复制下面的完整登记码粘贴进去。二维码和登记码内容一样，别让别人拍到。登记码只包含随机密钥，也应仅交给自己的手机。登记后默认自动解锁，无需逐次手机确认；手机端可以关掉自动开关，保留手动确认入口。
5. 使用已安装的同一 MacPeer 完成登记时，会重启登录自启的电脑端，使登记生效；其它启动方式请按界面提示重启。需要手动重启登录自启时，依次运行 `prototype/mac_peer/autostart.sh stop` 和 `prototype/mac_peer/autostart.sh start`，无需重新构建或签名。

**也可以从手机发起**（协议见 `docs/protocol.md`「手机请求显示登记码」）：Mac 解锁着时，在 App 里这台 Mac 的详情点「扫码登记」，后台电脑端会另起一个 `MacPeer.app --setup-unlock --phone-request` 窗口先问一句：已登记的点「显示二维码」就显示现有登记码（不换密钥、不用输密码），也可以选「重新登记…」；没登记的点「登记…」走上面第 3、4 步。不是自己点的就选「不用」，二维码不会出来。Mac 锁着屏时不弹（手机上会提示先解锁）。手机扫码保存后发来登记确认，窗口显示「已收到 iPhone 确认，即将关闭」后自己关（第一次登记时后台电脑端还没有密钥，要手动点「完成」）。只有从 `MacPeer.app` 起的电脑端（登录自启就是）才能弹窗。

本机模式不建立蓝牙服务，也不受已有电脑端的单实例锁限制：

```
open -n -a /实际路径/MacPeer.app --args --setup-unlock
/实际路径/MacPeer.app/Contents/MacOS/mac_peer --screen-status
/实际路径/MacPeer.app/Contents/MacOS/mac_peer --forget-unlock
```

`--screen-status` 只读检查当前会话、锁屏和权限，不读密码；`--forget-unlock` 删除本机登记，运行中的电脑端会拒绝后续请求。重新登记会更换随机密钥，旧手机登记不再有效，需重新导入并重启电脑端。

自动解锁仍要求电脑先看到手机走远再明显靠近；每个提示手机只自动尝试一次。启用后只接受已登记手机的新鲜签名信号报告，不恢复旧信号历史或提示；旧 App 可保持心跳，但不能触发靠近动作。权限、当前会话或安全密码框不确定时拒绝输入；失败后由用户正常手动解锁。真机上验证过：电脑请提示后，手机 1 到 2 秒发出签名请求，Mac 解锁并由系统确认。

## 运行

在「终端」里（终端要有蓝牙权限：系统设置 → 隐私与安全性 → 蓝牙）：

```
prototype/mac_peer/run.sh            # 真的锁屏
prototype/mac_peer/run.sh --no-lock  # 只记录本来会怎么做
prototype/mac_peer/run.sh --help     # 参数，和 win_peer.py 同名、同默认值（只有加密不一样：Mac 默认不加密，见「配对」）
```

第一次会先编译（要装 Xcode）。日志 CSV 写在当前目录，文件名 `peer_日期_时间_darwin.csv`。Ctrl+C 停止。

## 登录时自动启动（和 Windows 的 `install_autostart.ps1` 对应）

```
prototype/mac_peer/autostart.sh install              # 编译、装上并马上启动（真的锁屏）
prototype/mac_peer/autostart.sh install --no-lock    # 后面的参数原样传给 mac_peer
prototype/mac_peer/autostart.sh status               # 在不在跑、最近的日志
prototype/mac_peer/autostart.sh stop                 # 停止（下次登录还会启动）；start 再启动
prototype/mac_peer/autostart.sh uninstall            # 停止并删掉
```

- 装在 `~/Library/LaunchAgents/io.github.marriannedagwwn.MacPeer.plist`，launchd 直接运行 `MacPeer.app` 里的程序，蓝牙权限算 MacPeer 自己的。
- 意外退出（崩溃、被强制结束）launchd 隔 30 秒内重启；正常退出（stop、Ctrl+C）不重启。实测 `kill -9` 后约 15 秒重启，手机 0.4 秒内重新订阅。
- **只允许运行一份**（文件锁 `~/Library/Caches/proximity-unlock/mac_peer.lock`）：已经在跑时再用 `run.sh` 开一份，会打印一行就退出。两份会各加一个同样的协议服务。
- 日志在 `~/Library/Logs/proximity-unlock/`：`peer_*.csv` 是事件，`mac_peer_stdout.txt` 是原来打印到终端的内容。不放在仓库里：仓库在桌面这类受保护的文件夹里时，后台进程写进去要另外的「文件与文件夹」权限。
- 改了代码以后再 `install` 一次（会重新编译、重启）；签名变了系统可能再问一次蓝牙权限。
- **重新签名以后自动解锁要重新授权辅助功能**：临时签名的 App 系统按程序的哈希认，重签以后在辅助功能里还显示开着，其实不认了（系统日志 `Failed to match existing code requirement`）。而且系统的应用缓存里记着旧签名，在系统设置里删掉再「+」加回来，记下的还是旧的，照样不认。`build.sh` 重签以后会刷新这个缓存（`lsregister -f`），`autostart.sh install` 装完会查一次权限，「未授权」时提示去辅助功能里把 MacPeer 删掉再加回来。自动锁屏不受影响。以后可以考虑换成固定的签名证书，重装就不用每次重新授权。
- **重新签名以后第一次启动会卡在钥匙串弹窗**：本机登记存在钥匙串里，钥匙串也按程序的签名认，重签以后电脑端一启动读登记，系统就弹「MacPeer 想要使用钥匙串中的机密信息」，点之前电脑端一直停在启动这一步（不建蓝牙服务、不锁也不解锁，日志只有表头；`kSecUseAuthenticationUIFail` 拦不住这个弹窗）。输入登录密码、点「始终允许」就好了，以后同一个签名不再问。重新打包后记得看一眼 Mac 屏幕。

不在终端里运行时（比如从 Claude Code 里），`run.sh` 改用 `open` 启动 App，输出写到当前目录的 `mac_peer_stdout.txt`，
停止用 `pkill -INT -f MacPeer.app/Contents/MacOS/mac_peer`。

## 为什么打包成 App

macOS 的蓝牙权限按"负责的进程"查它 Info.plist 里的用途说明。在终端里跑，负责的是终端，没问题；
从 Claude Code 里直接跑命令行程序，负责的是 Claude Code，它没有蓝牙用途说明，程序会被系统直接结束。
所以 `build.sh` 把程序装进 `MacPeer.app`（带 `NSBluetoothAlwaysUsageDescription`，不显示 Dock 图标），用 `open` 启动时它自己负责。

App 放在 `~/Library/Caches/proximity-unlock/`（`MAC_PEER_BUILD_DIR` 可改），不放仓库里：仓库在开着 iCloud 同步的文件夹（比如桌面）里时，
放在里面签名会报 `resource fork, Finder information, or similar detritus not allowed`，编译产物也会被同步上去。

## 和 Windows 端的差别

- **锁屏状态**：先用 `CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked`；用 `open` 启动时它返回空（这台 Mac 上实测），
  就读 IORegistry 根节点的 `IOConsoleUsers`，当前用户那一项锁屏时会多出 `CGSSessionScreenIsLocked`。快速切换到别的用户也算锁着。
- **锁屏方法**：私有接口 `SACLockScreenImmediate`（login.framework），和菜单「锁定屏幕」一样，马上锁、不弹窗、不要辅助功能权限。
- **关显示器**：和 Windows 一样，自己锁屏 2 秒后关屏、记 `display_off`，用的是 `pmset displaysleepnow`（只关屏不睡眠，不要管理员权限）。用户自己锁的、`--no-lock` 时不关；`--keep-display` 关掉这一步。
- **点亮屏幕**：请手机提示解锁时用 `IOPMAssertionDeclareUserActivity` 声明一次用户活动（和动一下鼠标一样，锁屏照样锁着），记 `display_on`；提示被撤销时如果是自己点亮的，再关掉。只在真锁屏时做，`--no-wake` 关掉。
- **空闲秒数**：`CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`，取键盘、鼠标各类事件里最小的。
- **不让系统空闲睡眠**：运行期间默认不让系统睡（显示器照样会关），否则人一走 Mac 睡了，手机回来时连不上。`--allow-sleep` 关掉。
  同时也避免 App Nap 拖慢定时器。
- **默认不加密**：Windows 默认要求加密配对，Mac 默认不加密（`--secure` 打开），原因见下面「配对」。
- **没有守护进程和看门狗**：Windows 的卡死是 WinRT 特有的问题，Mac 上先不做。登录自启时意外退出由 launchd 重启。
- **启动时接上前一个进程**：未启用自动解锁时读同一个目录里上一个日志，最后一次锁屏之后没有 `back` 就还算离开、接着用原来的提示编号（`judge_restore`），并读回最近 `--ref-window + 60` 秒的报告算「走远时的信号」（`restore_reports`）。Windows 是同一个日志、卡死重启时读；Mac 每次启动换一个日志，所以读上一个。重启期间用户解锁了（现在没锁着）就不接。已登记自动解锁时不接旧信号和提示，必须先取得本次启动的认证报告。
- 手机连上时只知道 identifier，`device` 列写 `手机（identifier 前 8 位）`；`subscribe` 的 note 写最大通知长度。

## 配对

- iPhone 和 Mac 用的是同一个 Apple 账户时，Mac 会通过 iCloud 自动和这台 iPhone 配对（bluetoothd 日志里是 `Hidden BLEPaired CloudPaired`），**系统设置的蓝牙列表里看不到它，没法忘记**。
- 只要一边丢了配对（比如在 iPhone「设置 → 蓝牙」里忽略了 Mac），就再也连不上：
  - iPhone 还留着旧密钥时：每次连接都「Failed to encrypt the connection」（App 记 `connect_fail`、提示「加密超时」）。
  - iPhone 忘记以后：读 INFO 回「Encryption is insufficient」，手机发了配对请求，但 Mac 直接拒绝（`log show --predicate 'process == "bluetoothd"'` 里能看到「Denying pairing request … as there's no one to handle the request」），手机上不弹配对。系统设置的蓝牙页开着也没用。
- 所以 **Mac 电脑端默认不加密**，要加密时加 `--secure`；`--plain` 还认，和默认一样。Mac 的蓝牙地址是固定的，不配对 App 也认得出它（手机忘记配对前后 identifier 不变），心跳、REPORT 照常。Windows 会换广播地址，所以 Windows 端还是默认加密。
- 未登记时仍只交换心跳和信号；登记后对信号报告签名，并以 HMAC 一次性挑战认证解锁请求，不依赖链路配对。随机密钥离线登记，登录密码始终不离开本机。
- 多记两种事件：`bt_state`（蓝牙开关、没权限）、`add_service_error`。`start` 在服务加好以后记，蓝牙关了再开会再记一次。
- 心跳用 `updateValue` 发，它只是放进发送队列、马上返回；队列满时返回 false，`hb` 的 note 写 `ok=0/1 … 发送队列满`，不补发。

## 测试

```
cd prototype/mac_peer
swift test --scratch-path ~/Library/Caches/proximity-unlock/build
```

`Tests/PeerCoreTests` 用假的时钟、键盘鼠标和信号跑判断逻辑：坐着不动不误判、离开锁屏回来提示、手机失联、手机从没报告过不锁、自己锁屏坐着不提示、自己锁屏走开不到 60 秒不提示、提示后信号短暂掉一下不撤销、
自己锁屏后走开再回来提示、提示后又走远撤销再提示、回来要连续 3 秒 ≥ -72、撤销后解锁不算「提示后解锁」、`--no-lock`、启动宽限期、锁屏 2 秒后关屏（以及什么时候不关）、请提示时点亮屏幕和撤销时关回去，
心跳三档（每秒、3 秒、锁着 30 分钟没碰电脑就休眠；变慢先宣布再变；没锁屏不休眠；手机主动报的信号比走远时强 10 dB 才退出休眠、卧室里亮屏不算；手机连回来不休眠；旧 App 不休眠），
提示要比走远时强 10 dB（卧室里信号来回不提示、走开一会儿揣着手机回来照样提示、从外面回来不比），以及「走远时的信号」的算法和心跳、REPORT、INFO 的字节格式。

## 文件

| 文件 | 内容 |
|---|---|
| `Sources/PeerCore/Judge.swift` | 判断人在不在、锁屏、请手机提示解锁（照 `win_peer.py` 的 `Judge`） |
| `Sources/PeerCore/Proto.swift` | UUID、心跳 / REPORT / INFO 的字节格式、CSV 日志 |
| `Sources/mac_peer/main.swift` | 蓝牙外设（`CBPeripheralManager`）、系统接口、参数、状态输出 |
| `Sources/PeerCore/UnlockProtocol.swift` | REPORT 签名、新鲜度/重放校验、HMAC 一次性挑战及连接门禁 |
| `Sources/MacHost/` | 系统接口、安全 AX 密码框工作流、钥匙串及本机登记界面 |
| `Info.plist` | 打包 App 用：蓝牙用途说明、不显示 Dock 图标 |
| `build.sh` / `run.sh` | 编译打包、运行 |
| `autostart.sh` | 登录时自动启动（LaunchAgent） |
