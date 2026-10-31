# 蓝牙协议和判断规则

iPhone App 和电脑端（Windows、Mac）之间的蓝牙协议，电脑怎么判断人在不在、什么时候锁屏和请手机解锁，以及靠近自动解锁的应用层协议。多字节整数**全部是小端**。

版本：

- **v0**：只验证 iPhone 锁屏揣兜里时，能不能一直连着电脑、稳定测到信号。心跳 5 字节。
- **v1**：电脑判断人在不在、锁屏、请手机提示解锁。心跳 7 字节（加提示编号）。
- **v1.2**：心跳快慢和休眠。心跳 8 字节（加「下一次最晚几秒后到」），REPORT 7 字节（加 App 协议版本）。
- **应用层 v3**：靠近自动解锁（离线登记密钥、签名的信号报告、一次性挑战）。早期设想的 v2（用蓝牙特征 KEY 下发密钥、每次在手机上点按钮确认）没有实现，已被 v3 取代，电脑端不开放 KEY 特征。

## 角色

- **电脑 = 外设**（GATT 服务端）：广播服务，等手机来连，按节奏发心跳。
- **iPhone = 中心**：连电脑、订阅心跳；每收到一次心跳就读一次这条连接的 RSSI，写回电脑。

为什么这样分：

- Windows 作为中心读不到已连接设备的 RSSI，iPhone 作为中心可以（`CBPeripheral.readRSSI()`）。
- iOS 后台的中心能一直保持连接；挂起的 `connect()` 不会超时，手机回到范围内自动连上。
- 后台 App 只在有蓝牙事件时才被唤醒，所以靠电脑推心跳定时唤醒它。
- 不靠电脑扫描 iPhone 的广播：iPhone 锁屏后广播很稀疏，电脑有时十几秒都收不到一次，地址还会变。连着以后采样不靠广播，断开本身也是明确的「离开」信号。

## UUID

| 名称 | UUID | 属性 | 方向、什么时候有 |
|---|---|---|---|
| 服务 | `74cb8b6c-6eb7-4eed-bbcd-0a37f0ac77d7` | | 电脑广播里带这个服务 UUID |
| HEARTBEAT | `2399f9b5-b3ca-43ee-966d-d669401a5ed4` | notify, read | 电脑 → 手机 |
| REPORT | `ba3e7281-d451-4a7f-a305-150c789f1460` | write, write without response | 手机 → 电脑 |
| INFO | `a82beb9a-cba0-4974-8df3-2c8cf3052899` | read | 电脑 → 手机 |
| CHALLENGE | `0c28c82e-69ec-4cd1-ab3b-ea7e160fcd3c` | read | 电脑 → 手机。登记了自动解锁才有 |
| UNLOCK | `54cd9a6f-36e3-4c39-b875-bbeee5f1aef1` | write（要回复） | 手机 → 电脑。登记了自动解锁才有 |
| ENROLL_ACK | `be282b23-6b55-4b86-86ea-b7f8f3c273e3` | write（要回复） | 手机 → 电脑。和 CHALLENGE / UNLOCK 一起开放 |
| ENROLL_REQUEST | `3465d7ce-93d4-4d36-9c16-0619b8ebadbf` | write（要回复） | 手机 → 电脑。有没有登记都开放 |
| LOCK | `10c0be5d-68ca-44bd-87ce-a2e42e9604da` | write（要回复） | 手机 → 电脑，让电脑锁屏。和 CHALLENGE / UNLOCK 一起开放 |

- Windows 电脑端默认所有特征值都要求加密（`--plain` 关掉），iPhone 第一次访问时系统弹配对；Mac 电脑端默认不加密（`--secure` 打开），原因见「Mac 电脑端的要点」。
- 广播包里放不下 128 位服务 UUID 再加电脑名，所以 App 要连上读 INFO 才知道名字。
- iBeacon（实验）用另一个 UUID `9E698AEC-9C56-46E3-9209-F2628704D932`，见「用 iBeacon 拉起 App（实验）」。

## 数据格式（全部小端）

### HEARTBEAT

v1.2 是 8 字节 `<IBHB`（v1 是前 7 字节 `<IBH`，v0 是前 5 字节 `<IB`）。读的一方只看认识的字节，长短版本互相兼容。HEARTBEAT 也能读，读到的是当前这一份。

| 偏移 | 类型 | 含义 |
|---|---|---|
| 0 | uint32 | seq，每次心跳加 1 |
| 4 | uint8 | 电脑状态：0 未知，1 未锁屏，2 已锁屏，**3 已锁屏并请手机提示解锁** |
| 5 | uint16 | 提示编号：每次新的解锁提示加 1，电脑端每次启动换一个起点。App 看到状态 3 并且编号和上次弹过的不一样，才弹新通知 |
| 7 | uint8 | 下一次心跳最晚几秒后到（向上取整，最大 255），App 的看门狗按它放宽。没有这个字节就按 5 秒 |

### REPORT

v1.2 的 App 发 7 字节 `<IbBB`，用 write without response；旧电脑端只读前 6 个（`<IbB`）。

| 偏移 | 类型 | 含义 |
|---|---|---|
| 0 | uint32 | 触发这次测量的心跳 seq，电脑用它算往返延迟 |
| 4 | int8 | 读到的 RSSI（dBm）；读不到填 127 |
| 5 | uint8 | 手机自己判断的状态：0 未定，1 靠近，2 离开（只作参考） |
| 6 | uint8 | App 的协议版本：写 2 表示认识心跳里「下一次最晚几秒」，电脑端才会进休眠。没有就当 1 |

### 认证 REPORT（v3，35 字节）

登记了自动解锁的电脑只让这种报告参与判断。App 用 write with response 写（Windows 端不收 write without response 的认证报告），电脑核对通过才回成功。

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0 | 7 | 上面的 7 字节 REPORT |
| 7 | 4 | `keyID`（uint32） |
| 11 | 8 | 每包随机数，每条都换 |
| 19 | 16 | HMAC-SHA256(`secret`, 消息) 的前 16 字节 |

消息 = UTF-8 `"proximity-report-v1"` ‖ `reportNonce`（16 字节，从 INFO 读，base64 解开） ‖ 包的前 19 字节。

### INFO

UTF-8 JSON，例如 `{"proto": 1, "platform": "win32", "name": "DESKTOP-ABC123"}`。

| 字段 | 含义 |
|---|---|
| `proto` | 电脑端的协议版本，两边都写 1。比 App 自己的版本新时 App 提示更新 |
| `platform` | `win32` 或 `darwin` |
| `name` | 电脑名，比如 `DESKTOP-ABC123`、`我的 Mac mini` |
| `unlock` | 登记了自动解锁才有：Windows `win-hmac-v3`，Mac `ax-hmac-v3` |
| `reportNonce` | 登记了才有：本次电脑端进程随机生成的 16 字节，base64。认证 REPORT 和登记确认都绑定它，电脑端重启就换 |
| `manual` | 登记了、支持手动锁屏和解锁才有，写 1，见「手动锁屏、解锁」 |

### CHALLENGE、UNLOCK、ENROLL_ACK、ENROLL_REQUEST、LOCK

- **CHALLENGE**（读）：18 字节 `<H16s>`，当前提示编号 + 这次提示的 16 字节随机数。电脑锁着、没在请提示时编号是 0（手动解锁）。
- **UNLOCK**（写）：22 字节 `<IH16s>`，`keyID` + 提示编号 + 签名。签名 = HMAC-SHA256(`secret`, UTF-8 `"unlock-v2"` ‖ 提示编号（2 字节） ‖ 随机数（16 字节）) 的前 16 字节。`unlock-v2` 是早期草案留下的名字，为了兼容没改。
- **ENROLL_ACK**（写）：20 字节，`keyID` + HMAC-SHA256(`secret`, `"enroll-ack-v1"` ‖ `reportNonce` ‖ `keyID`（4 字节）) 的前 16 字节。
- **ENROLL_REQUEST**（写）：1 字节 `0x01`（版本）。
- **LOCK**（写）：32 字节，`keyID`（4 字节） + 手机收到的最近一次心跳 `seq`（4 字节） + 每包随机数（8 字节） + HMAC-SHA256(`secret`, UTF-8 `"lock-v1"` ‖ `reportNonce` ‖ 前 16 字节) 的前 16 字节。

### 离线登记码

`{"version": 1, "keyID": 2018915346, "secret": "<32 字节，base64>"}`，不含登录密码。电脑的登记窗口显示这段 JSON 和它的二维码（内容一样，纠错等级 M），手机扫码或粘贴导入，不经过蓝牙。

### 回复的错误码

| 码 | 意思 |
|---|---|
| `0x07` | Invalid Offset |
| `0x08` | 认证 REPORT 没通过（Insufficient Authorization） |
| `0x0D` | 长度或内容不对（Invalid Attribute Value Length） |
| `0x80` | CHALLENGE / UNLOCK：现在不能解锁（没锁着、提示编号或 `keyID` 对不上、这条连接没有新鲜的认证报告、正在执行上一次、失败太多次）。LOCK：这条连接没有新鲜的认证报告，或者没开真锁屏 |
| `0x81` | UNLOCK / ENROLL_ACK / LOCK：签名或 `keyID` 不对。ENROLL_REQUEST：电脑锁着屏 |
| `0x82` | CHALLENGE / UNLOCK：过期了，或者没有可用的随机数。LOCK：心跳 `seq` 过期或者重放。ENROLL_REQUEST：电脑弹不出窗口 |
| `0x83` | UNLOCK：签名对，但系统没解开。LOCK：锁屏失败 |

### 固定测试向量

`secret` = `00 01 … 1f`（32 字节），`keyID` = `0x78563412`，`reportNonce` = `00 01 … 0f`。Python（`tests/test_win_unlock_protocol.py`）、Swift（Mac 端 `Tests/`、`ios/test-unlock-codec.sh`）用同一组，ENROLL_ACK 用 openssl 独立核对过。

| 什么 | 其他输入 | 结果（hex） |
|---|---|---|
| CHALLENGE | 提示编号 `0x1234`，随机数 `00 01 … 0f` | `3412000102030405060708090a0b0c0d0e0f` |
| UNLOCK 的签名 | 同上 | `4b78d367ade22f9aee438984eccfd654` |
| UNLOCK | 同上 | `1234567834124b78d367ade22f9aee438984eccfd654` |
| 认证 REPORT | 基础报告 `<IbBB>`(`0x01020304`, -60, 2, 2)，每包随机数 `00 01 … 07` | `04030201c40202123456780001020304050607fe75e30883ae3552ab7196d247dfdab9` |
| ENROLL_ACK | | `12345678e8a232851651af8c3a8c9efbbeb9ab78` |
| 手动解锁的 UNLOCK | 提示编号 0，随机数 `00 01 … 0f` | `1234567800004a778d2cb1f5141a5d8edd20c871dac0` |
| LOCK | `seq` `0x11223344`，每包随机数 `00 01 … 07` | `12345678443322110001020304050607442b75904bb993b827ddb143ec6926a8` |

## iPhone 端流程

1. **添加电脑**：按服务 UUID 搜索，搜到的先连上读 INFO，列表显示 `name`；点了就记住 `peripheral.identifier`。能同时记住、连接多台电脑，每台各走下面的流程，互不影响。
2. **发现服务、订阅、读 INFO**：订阅 HEARTBEAT，读一次 INFO。每台电脑同时只发现一轮：发现中服务又变了（Windows 一连上就会发服务变化）就等这一轮完了再来一次，不然几轮叠在一起会重复订阅、连着读很多次 INFO。INFO 每条连接读一次，电脑端程序重启过再读一次：Windows 端靠读 INFO 恢复暂停的心跳，但每次读都是一次跨进程 WinRT 调用，不该连着读。
3. **每收到一次心跳**：`readRSSI()`，在 `didReadRSSI` 里写 REPORT。iOS 读一次 RSSI 约 1.05 秒，比心跳间隔还长，排队读的话延迟越积越大，所以**同时只读一次**：读的时候来的心跳只留最新一次，更早的不回（记 `skip`），往返延迟稳定在 1 到 2 秒。按电脑分别读，互不阻塞。登记了自动解锁的电脑写 35 字节认证 REPORT，写入容量不够时这包不发、自动解锁暂停。
4. **断开后立即 `central.connect(peripheral)`**，挂起等重连。同时按服务 UUID 搜索（电脑可能换了地址）：搜到不认识的设备就连上读 INFO，名字和某台没连上的电脑一样就改连它、更新 identifier（`adopt`），不一样就断开；连不上的 60 秒内不再试，同时最多核对 3 台。只靠名字能被冒充，只是兜底，正经办法是配对。不在 iBeacon 区域里、并且在后台时不搜，挂着的 `connect` 留着（系统维持，很省电）。
5. **连着但没有协议服务**（电脑端程序停了，Windows 不会因此断开）：每 3 秒找一次服务，30 秒没有就主动断开重连。配对过的电脑往往断不开（系统不放链路，0 秒又连上），就只断一次，之后连着等：前台每 3 秒找，后台靠服务变化通知（`didModifyServices`）。
6. **心跳看门狗**：订阅 40 秒没完成（可能在弹配对），或者 5 秒没心跳，就 `cancelPeripheralConnection` 再重连，强制重新发现、重新订阅。连续触发时等待翻倍（5、10、20、40、60 秒封顶），收到心跳复位。电脑宣布了「下一次最晚几秒」时按它加 3 秒（至少 5 秒，休眠时 33 秒），断开重连后也按它等，不然休眠的电脑会被反复断开重连。对付的是电脑端卡死重启：新服务在同一条没断的连接上，App 收不到断开事件；配对过的电脑其实断不开链路，「断开重连」的作用是重新发现、重新订阅。
7. **旧服务**：电脑端进程被强制结束后，它的服务要过几分钟才被系统清掉，iPhone 可能看到不止一个协议服务，或者记着旧的服务结构：订阅「成功」但没心跳、读 INFO 回 `Unlikely error`，或者都回「句柄无效」。不止一个时记 `service_dup`；碰到这两种错误或看门狗触发就换下一个（`service_switch`）；只有一个或换遍了，连续两轮就提示「去 iPhone 设置里关开一次蓝牙」（`stale_service`），收到心跳撤掉。电脑端没在运行、电脑在睡眠时症状也一样。
8. **加密和配对**：电脑要求加密时，iOS 在第一次订阅或读 INFO 时自己弹配对。用户没点「配对」时订阅失败（`Encryption is insufficient`），App 提示后点「重新连接」再弹；电脑删了配对（`peerRemovedPairingInformation`）要在 iPhone 蓝牙设置里「忽略此设备」。**加密超时**第一次马上重新挂连接请求（`encrypt_retry`，不靠定时器，App 在后台被挂起时定时器不走），60 秒内又超时才放慢到 10 秒、提示配对问题：Windows 在现代待机里时，手机回来第一次连接常常加密超时，链路两三秒后就自己回来了。
9. **后台运行**：`UIBackgroundModes` 加 `bluetooth-central`；用 `CBCentralManagerOptionRestoreIdentifierKey` 做状态恢复，系统把挂着的连接一起交回来，每台电脑按 identifier 接回自己的；重连用 `retrievePeripherals(withIdentifiers:)`。App 被划掉、手机重启以后状态恢复管不到，见「用 iBeacon 拉起 App（实验）」。
10. 事件都记到手机 CSV，能导出和电脑端的日志对照（`link_analyze.py`）。

## v0 要回答的问题

`link_analyze.py` 按这 4 个问题分析日志。结论：

1. **手机锁屏放兜里，连接会不会断？每秒能拿到几次 RSSI？** 不会断，REPORT 每秒约 1 次。会出问题的是 Windows 电脑端：发心跳的 WinRT 调用会卡住不返回，靠守护进程重启（见「Windows 电脑端的要点」）。
2. **人坐着（手机在兜里）、1 米、3 米、门口、隔壁时，连接 RSSI 各是多少？** 没逐个位置测过。揣兜里坐在电脑前每分钟的中位数在 -68 到 -76，走到别的房间 -83 到 -85，只差 8 到 10 dB（用 `rssi_probe.py` 扫广播时，揣兜里和 3 米外也只差约 5 dB）。单看信号分不开，所以由电脑结合键盘鼠标判断。
3. **走开以后多久断开？回来以后多久重新连上？** 没系统测过。手机走远后报告先停，链路看起来还要约 10 秒才被系统拆掉。回来时手机常在 -88、-89 就连上，比「回来了」的阈值远得多，所以提示时机由信号决定，不由重连决定。
4. **电脑端程序重启后，iPhone 能不能用原来的 identifier 自动重连？广播地址会不会变？** Windows 不配对时每次重新广播都换随机地址，iPhone 拿不到电脑的身份密钥（IRK），当成新设备，所以 Windows 端默认要求配对，App 另有按名字的兜底；Mac 的地址固定。配对后电脑端程序重启时 Windows 不断开连接，只是服务换了，App 靠「iPhone 端流程」第 5 到 7 步恢复。

## 手机自己的判断（REPORT 的状态字节）

只作参考，电脑不靠它锁屏。规则在 App「工具与记录」→「手机判断参数」里能改：最近 5 次 RSSI 的中位数 ≥ -76 算靠近（最早是 -70，升级时自动改）；< -80 持续 10 秒算离开；中间保持原状态；断开直接算离开。App 每次启动记一行 `settings`。

为什么不靠它：揣兜里坐着和走到别的房间只差 8 到 10 dB。判成离开以后，人回来坐下信号是 -74、-75，正好落在「保持」区间里，状态一直停在离开；调阈值也只能勉强分开，换个坐姿就可能误判。

## 电脑怎么判断人在不在、锁屏、请手机提示解锁

电脑知道一件手机不知道的事：有没有人在用它。所以人在不在由电脑判断：键盘鼠标空闲多久，加上手机的信号、手机在不在。Windows 是 `prototype/win_peer.py` 的 `Judge`，Mac 是 `prototype/mac_peer/Sources/PeerCore/Judge.swift`，规则、参数名、默认值一样，单元测试场景也对应（`tests/test_win_peer_judge.py`、`Tests/PeerCoreTests/JudgeTests.swift`）。每秒判断一次。

| 参数 | 默认 | 意思 |
|---|---|---|
| `--active` | 30 秒 | 这么久以内动过键盘鼠标就算在电脑前 |
| `--idle-lock` | 60 秒 | 至少这么久没动才可能判定离开 |
| `--lost-for` | 10 秒 | 手机失联这么久算离开 |
| `--far-th`、`--far-for` | -80、10 秒 | 信号中位数低于 -80 持续 10 秒算离开 |
| `--pause-after` | 3 秒 | 这么久没报告算失联、停发心跳（心跳慢下来时跟着放宽） |
| `--startup-grace` | 30 秒 | 电脑端启动后这么久以内不算失联 |
| `--cancel-after` | 60 秒 | 手机持续走远这么久才算「走远过」、才撤销提示 |
| `--freeze-away` | 60 秒 | 电脑端被待机、睡眠冻住这么久，醒来锁着就当作走远过（见「请手机提示解锁」） |
| `--approach-th`、`--approach-for` | -72、3 秒 | 回来时信号中位数要连续 3 秒 ≥ -72 |
| `--approach-gain` | 10 dB | 还要比「走远时的信号」强这么多（退出休眠也用） |
| `--ref-window` | 900 秒 | 「走远时的信号」看最近这么久的报告（不含最近 30 秒） |
| `--interval`、`--slow-th`、`--slow-interval` | 1 秒、-75、3 秒 | 心跳间隔和慢档 |
| `--dormant-after`、`--dormant-interval` | 1800 秒、30 秒 | 休眠 |
| `--no-lock` | | 只记录本来会怎么做（`would_lock`、`would_prompt`），不真的锁屏 |

两边各自还有屏幕、看门狗、加密、登记等参数，见各自的 `--help` 和下面的「要点」。

### 在电脑前、离开

- **在电脑前**：`--active` 秒内动过键盘鼠标，不管信号多少。
- **离开**：`--idle-lock` 秒没动，**并且**手机失联 `--lost-for` 秒、或者信号中位数低于 `--far-th` 持续 `--far-for` 秒。都不是就是「没在操作」。状态变了记 `judge`。
- 中位数取最近 5 条、并且在最近 `max(10, 心跳间隔 × 2 + 2)` 秒内的报告（127 不算）。失联 = 没有手机订阅着，或者超过 `--pause-after + (心跳间隔 − 1)` 秒没报告；不能看订阅，配对过的手机离开时 Windows 不报告取消订阅。启动后 `--startup-grace` 秒内不算失联。
- **这次启动以来没收到过报告，失联就不算离开**：分不清「手机走了」和「手机根本没连这台电脑」（比如 App 还没添加它），宁可不锁。例外：7 天内收到过报告、或者登记过自动解锁，重启后失联照样算离开，不然电脑端在手机不在时重启以后就再也不锁了。启动时从日志找最后一次报告的时间，记 `phone_known`（note 带 `last=<Unix 秒>`）。
- **手机走后只锁一次**：锁过一次以后、手机还没回来就被解开了，记 `lock_hold`，之后判定离开也不锁（记 `lock_skip`）；手机回到电脑附近（和请提示的「回来了」同一个条件）恢复，记 `lock_resume`；重启时从日志接上。原因：远程操作这台电脑时，操作停一下不应该就锁，可电脑分不出远程操作（远程控制软件的输入和本机键盘鼠标在系统里一样），靠笔记本发的 iBeacon 判断人在不在家也不行（笔记本可能跟着人走）。代价：知道开机密码的人在手机回来前解开了电脑，也不会再锁。

### 锁屏和处理屏幕

- 判定离开 → 锁屏，记 `lock`（Windows `LockWorkStation`，Mac `SACLockScreenImmediate`）；已经锁着 note 写「本来就锁着」；`--no-lock` 时只记 `would_lock`。真实锁屏状态变了记 `locked` / `unlocked`。
- Windows 查锁屏用 `WTSQuerySessionInformation`（`WTSSessionInfoEx` 的 `SessionFlags`，0 是锁着），「打不开输入桌面就算锁屏」在 Windows 10 上检测不到。`LockWorkStation` 是异步的，还会刷新一次「上次操作时间」，所以「锁屏失败就看键盘鼠标」的兜底等 5 秒还没锁上才生效。
- 自己锁屏 2 秒后（等锁屏界面出来，免得被动画重新点亮）处理屏幕：Mac 关显示器，记 `display_off`（`--keep-display` 关掉）；Windows 按 `--screen`：`off`（默认）用 `SC_MONITORPOWER` 真关屏，`dim` 亮度调到 0（记 `dim`，回来恢复记 `undim`），`keep` 不动。用户自己锁屏（或屏保锁的）、之后判定离开时，Windows 和 Mac（Mac 电脑端 0.1.2 起）也马上处理，不等 2 秒。

### 请手机提示解锁

- **走远过**（armed）：锁屏期间失联或信号弱**持续 `--cancel-after` 秒**。信号在阈值附近跳、偶尔几秒没报告都不算，不然会反复撤销、重弹通知。用户自己按 Win+L、人还坐着时不会 armed，一锁屏不会弹通知。
  - **判定离开不算走远过**：判定离开只要失联或信号弱 `--lost-for` / `--far-for` 秒（10 秒），这时「走远时的信号」还没有报告，「强 10 dB」的比较会被跳过，手机在屋里、信号只跌了一下，回到 -72 就会请提示、自动解锁。代价：走开不到 1 分钟就回来，不提示。（Windows 电脑端 0.1.1 起，Mac 电脑端 0.1.2 起。）
  - **冻住期间走开**：两次判断隔了 `--freeze-away` 秒以上（电脑端被待机、睡眠冻住了，卡住的话看门狗几秒就重启了），醒来时锁着，就当作冻住期间走远过，起点是冻住那一刻，记 `freeze_away`。不然走开时合了盖、冻住前还没判定离开的话，醒来后手机马上连回，电脑端却没见手机走过，一直不提示。要等显示器亮了（按电源键、开盖、动鼠标）才算：待机里的维护唤醒显示器不亮、盖子可能合着，这时手机在旁边也不解，只记一次 `freeze_wait`。Windows 看 `GUID_CONSOLE_DISPLAY_STATE`，订阅失败时记 `freeze_watch`、不等显示器；Mac 看 IOPMrootDomain 的「System Capabilities」（维护唤醒没有图形能力）和 `CGDisplayIsAsleep`。代价：合盖时人没走、手机一直在旁边，过一会儿开盖按电源键也会自动解锁。（Windows 电脑端 0.1.1 起，Mac 电脑端 0.1.2 起。）
- **回来了**：信号中位数 ≥ -72，**并且比走远时的信号强 10 dB**，**连续 3 秒**，手机没失联。
- 走远过又回来了 → 心跳状态改成 3、提示编号加 1，记 `prompt`（`--no-lock` 时 `would_prompt`），note 像「id=778，离开 600s 后，比走远时（-82）强 14 dB」或「之前一段没有报告（手机刚连回来）」。
- **走远时的信号**（`Judge.reference`）：走远的起点以后、最近 `--ref-window` 秒（不含最近 30 秒）报告里**信号强的那一头（90% 分位）**；少于 3 条（手机从外面回来）就不比，只看 -72。只看走远以后的，因为坐着时手机放桌上（-55 左右）比揣着手机走回来（-68 左右）还强。用强的那一头不用中位数，因为手机放在别的房间时信号可能整夜停在 -70 上下、被挡一下就掉到 -82 停几分钟，拿中位数当参考，回到 -72 正好强了 10 dB，照样半夜提示。起点取 armed 时失联、信号弱里更早的那个（冻住醒来时是冻住那一刻）；`back`、用户自己解锁时清掉，**撤销提示时重设成这次走开的起点**（不然参考里还有上次回来时的强信号）。
- **为什么这样定**：只看绝对阈值（原来 ≥ -78 就提示）时，手机在蓝牙范围边上信号一跳就算回来，人不在、夜里都会反复误提示。从信号变好到提示约 5 到 6 秒，人一般还在两三米外。代价：揣着手机走到电脑前可能不提示，要拿在手里才提示。
- **撤销**：提示后又持续走远 `--cancel-after` 秒 → 状态回到 2，记 `prompt_cancel`，清掉提示时间；再回来用新编号提示。
- **亮屏**：Mac 请提示时 `IOPMAssertionDeclareUserActivity`（和动一下鼠标一样），记 `display_on`（`--no-wake` 关掉），撤销时把点亮的再关掉。Windows 调暗过的先恢复亮度（`undim`），撤销时再调暗，不然自动解锁没成、要手动输密码时对着亮度 0 的锁屏，按键也亮不起来。
- `--no-lock` 时心跳状态按「本来会锁屏」填，不锁屏也能测通知。

### 回来了、重启以后接上

- 解锁了（`--no-lock` 时是又动了键盘鼠标）→ 状态回到 1，记 `back`，note 写离开多久、提示后多久解锁，或者「没提示就解锁了」。
- 没登记自动解锁时，重启后从日志接上前一个进程：最后一次锁屏后没有 `back` 就还算离开，正在提示就沿用原来的编号（手机不重复弹），记 `judge_restore`；再读回最近 `--ref-window + 60` 秒的报告算参考，不然一重启就可能误提示。Windows 读同一个日志；Mac 读上一个 `peer_*_darwin.csv`（`restore_reports`），重启期间用户解锁了就不接。登记了自动解锁时只接 `phone_known`、`lock_hold`，不接旧的信号和提示（旧报告没法重新验签）。

### Windows 的现代待机和电源请求

支持现代待机（S0）的笔记本锁屏、关屏后很快进待机，电脑端可能被暂停，手机回来连上也没人应答。

- **锁着就开电源请求**（`PowerSetRequest` 的 SystemRequired + ExecutionRequired），不管是谁锁的，记 `keep_awake`，最多 `--awake-minutes`（判定离开时重新算）；到时间或解锁了放开，记 `allow_sleep`（到时间放开以后再回来，用电池时要先按键唤醒）。一锁屏就开，是因为用电池时锁屏后很快就进待机，约 15 秒后电脑端被暂停，等判定离开再开就晚了。
- 电源请求挡不住进待机；能不能挡住电脑端被暂停，看是怎么进的待机（Kernel-Power 506 的 Reason）：

  | 怎么进的待机 | 电源请求 | 电脑端在待机里 |
  |---|---|---|
  | 系统闲置关屏（Reason 12） | 有，或者插着电 | 一直在跑，自动解锁还会把电脑叫醒 |
  | 系统闲置关屏，用电池 | 没有 | 约 15 秒后停住 |
  | **电脑端发 `SC_MONITORPOWER` 关屏（Reason 3）** | 有 | **被冻结**（插着电也一样），直到按键 |
  | 合盖、电源切换、维护唤醒后再进 | 没有 | 被冻结 |

- 所以默认的 `--screen off` 锁屏后马上黑屏、最省电，代价是电脑因此进了待机以后，手机回来不会自动解锁，要先按一下键（之后手机连着就会请提示、自动解锁）。不想要就用 `--screen keep`（锁屏界面约 30 秒后系统自己关屏，进的是闲置待机）或 `--screen dim`。离开超过 `--awake-minutes` 时调暗的先恢复亮度再真关屏，让电脑去待机省电。待机里手机回来第一次连接常常加密超时，见「iPhone 端流程」第 8 步。

## 心跳快慢和休眠

每发一次心跳就把手机上的 App 叫醒一次。电脑锁着、人在睡觉时每 1 到 3 秒叫醒一次，一晚上上万次，耗手机电；Windows 端发得越勤也越容易卡死。iBeacon 管不了「在家睡觉」：区域监测只分在不在范围里（几十米），手机在家里哪个房间都在范围里。所以：

- **出了门**（区域外）：电脑这边失联 3 秒就停发心跳；App 在后台时停止找没连上的电脑，进入区域再找。
- **在家、电脑锁着没人用**：心跳放慢到 30 秒一次（休眠）。休眠看锁了多久、多久没人碰，**不看信号**：别的房间的手机和揣兜里坐在电脑前的信号差不多（都在 -70 上下），看信号分不出「在家但离电脑远」。

三档（`Judge.heartbeat_interval` / `heartbeatInterval`），按顺序先满足哪条就是哪档：

| 档 | 条件 | 间隔 | 心跳最后一个字节 |
|---|---|---|---|
| 正常 | 有人在用电脑 | 1 秒（`--interval`） | 1 |
| 休眠 | 电脑锁着（`--no-lock` 时是判定离开了），并且 `--dormant-after`（30 分钟）没碰键盘鼠标；还要 App 报了协议版本 ≥ 2、最近一段有报告（「走远时的信号」算得出来）、最新一条没有比走远时强 `--approach-gain` | 30 秒（`--dormant-interval`） | 30 |
| 正常 | 信号中位数 ≥ -75，或者最新一条 ≥ -75，或者最近没有报告 | 1 秒 | 1 |
| 慢 | 没人用电脑、信号中位数 < -75（`--slow-th`） | 3 秒（`--slow-interval`） | 3 |

- **慢档**：手机在远处（信号 -80 到 -95）而报告还在收时，Windows 端发心跳最容易卡死。旧 App 5 秒收不到心跳就重连，所以慢档不能超过 4 秒。进入看中位数，退出只要最新一条够强。
- **退出休眠**：有人碰了电脑、解锁了、**最新一条报告比走远时强 10 dB**（和请提示同一个参考），或者最近一段没有报告（手机从外面回来）。休眠时中位数窗口里只有两三条，所以看最新一条。在别的房间拿起手机看一眼（App 亮屏时主动报一条）不会退出；拿着手机走向电脑就马上恢复每秒一次。
- **变慢先宣布再变**：宣布过「下一次最晚 1 秒」的，下一次还是 1 秒后发，这一次才宣布 30；**变快马上生效**（`HeartbeatSchedule`，每 0.25 秒看一次）。
- 失联阈值和中位数窗口跟着间隔放宽：失联 = 超过 `3 + (间隔 − 1)` 秒没报告（休眠时 32 秒），中位数取最近 `max(10, 间隔 × 2 + 2)` 秒（休眠时 62 秒）。
- 旧 App（报告里没写版本）最多到慢档：它的看门狗固定 5 秒，30 秒一次心跳会让它反复重连，反而更耗电。
- 间隔变了电脑端记 `hb_rate`（note 像 `心跳间隔 3s → 30s（休眠）`），Windows 端 App 协议版本变了记 `app_proto`。电脑锁着过夜时，一整夜只有一千次左右心跳（每秒一次是三万次左右）。

**App 这边**：看门狗按心跳最后一个字节放宽（「iPhone 端流程」第 6 步），间隔变了记 `hb_interval`。**被叫醒时主动报一次**：在 iBeacon 区域里亮屏（`notifyEntryStateOnDisplay` 送的状态事件）或者进入区域时，对每台连着、最近宣布的间隔 ≥ 10 秒的电脑读一次 RSSI、写一条 REPORT（seq 用最近一次心跳的），记 `report_wake`；正在读的不另读，自己 `requestState` 的回复不算，多要 20 秒后台时间。

## iPhone 端怎么处理提示

实现在 `ios/ProximityUnlock/UnlockPrompter.swift`。

- 心跳里电脑状态是 3、提示编号和上次弹过的不一样 → 发本地通知「DESKTOP-ABC123 已锁屏，是你回来了吗？」。App 在后台被心跳唤醒的那几秒里就能发；在前台时也弹横幅。通知权限在 App 第一次回到前台时申请。
- 电脑状态不再是 3 → 从通知中心撤掉。**断开连接时不撤**，只看电脑状态：断开就撤的话，电脑端卡死重启时提示还在、通知却没了，编号没变也不会再弹。
- 每台电脑一条通知（identifier 是 `unlock-prompt-` 加电脑的 key），新的替换旧的，只撤那台的。弹过的编号、通知在不在按电脑存在 UserDefaults 里，App 被系统重新拉起、电脑端沿用原编号时都不会重复弹，也不会忘了撤。
- 登记了自动解锁的电脑，通知上多一个「解锁」按钮（要先解开手机），确认后发签名请求；没登记的点通知只是打开 App。
- 日志 `prompt_shown`、`prompt_removed`（note 写 `id=N`），和电脑端的 `prompt` 对时间。横幅只停几秒、容易错过，所以 `prompt_shown` 还记下系统的通知设置；「工具与记录」里的「测试通知」5 秒后弹一条，用来确认锁屏上看得到。

## Windows 电脑端的要点

`prototype/win_peer.py`（Python + WinRT，只依赖 `bleak` 装进来的 winrt 包），`prototype/install_autostart.ps1` 装成登录时启动，只允许运行一份。

**守护进程和看门狗**：WinRT 发心跳的调用（`notify_value_async`）可能卡在跨进程调用系统蓝牙服务那一步再也不返回，iPhone 断开也不返回；卡在同步部分时还**一直占着 Python 的 GIL**，同进程里的线程都救不了。所以守护进程启动工作进程，工作进程每 0.5 秒往共享内存写时间戳（有心跳在发、还没完成时写它开始的时间），守护进程超过 `--stuck`（5 秒）看不到更新就强制结束、2 秒后重启（连着出问题就逐渐拉长，最多 60 秒），日志接着写同一个文件，记 `stuck`。发心跳正常耗时 99% 在 16 毫秒以内。

- 现场取证：可能卡住的调用之前往共享内存写标签（`notify`、`subscribed_clients`…，心跳超过 1 秒没完成写 `notify:pending`），卡死时记进 `stuck` 的 note，并用 py-spy 抓调用栈存到 `<日志名>_stuckN.txt`。`--simulate-stuck 秒` 模拟占着 GIL 的卡死。
- 待机冻结不算卡死：现代待机冻结进程时两个进程一起停，维护唤醒时守护进程先醒，会把很久没更新的时间戳误判成卡死。所以守护进程发现自己隔了超过 `--stuck` 秒才转一圈（`StallWatch`），就记 `supervisor_resume`、给 10 秒缓冲，不判卡死、不修广播。
- 守护进程和工作进程都往同一个日志里写，偶尔同时写会把一行写坏（留下半个汉字）。启动时读日志接状态，读不出来的字节换掉、时间读不出来的行跳过，不然工作进程一启动就崩、一直重启（0.1.1 起）。
- 往正在断开或已经断开的连接上发心跳，调用可能永远不完成；人坐着时也卡过，原因不明，靠看门狗兜底。

**停发心跳**：手机 `--pause-after` 秒没回报告就停发，手机自己有回应（报告、重新订阅、读 INFO）再恢复，记 `hb_pause`、`hb_resume`；**不试探**（试探着发一次正好撞上链路拆除就会挂住）。订阅着的手机底层链路都报了 `DISCONNECTED` 就马上停（note「底层链路断开」），有几台手机时还有一台连着就照发。配对过的手机离开时 Windows 不报告取消订阅，回来也没有新的订阅事件，所以「读 INFO 也算有回应」是必要的；`link` 记底层链路的断开、连上。

**协议广播坏了（ABORTED）**：

- 手机订阅着我们的服务时把服务撤掉（卡死重启、手动重启，正常退出也一样），之后整台电脑新开的可连接广播都是 ABORTED，**只有关开一次蓝牙能恢复**；手机没连着时重启不会坏。有的程序（比如某些手机互联软件）会在蓝牙打开约 4 秒后占住可连接广播，所以关开以后要马上启动电脑端。
- 广播坏着配对过的手机照样连得回来（GATT 服务全系统共用）；我们的广播只在按服务 UUID 搜索时用得着，所以这时在 App 里忘记这台电脑再重新添加会搜不到。
- 手机连着时不重开广播（这时停了再开，之后几秒的心跳常常卡死）；手机断开了才按 10 秒、20 秒……最多 5 分钟重开（`adv_retry` / `adv_ok`）。
- 自动修：广播坏了超过 `--adv-repair-after`（30 分钟）、人不在电脑前（锁着或 10 分钟没碰）、离上次修超过 `--adv-repair-gap`（3 小时），守护进程就请工作进程正常退出、用 `prototype/bt_toggle.py` 关开一次蓝牙，**一打开就马上启动工作进程**（`adv_repair`、`adv_repair_done`）。手动修、或者手机订阅着时要手动重启电脑端，也按这个顺序：正常退出 → `bt_toggle.py --settle 0` → 马上启动。
- 正常退出：手动停止（`install_autostart.ps1 -Stop`）和自动修都通过命名事件 `Local\iphone-proximity-unlock-win-peer-stop` 告诉守护进程，工作进程停广播、撤服务再退（`stop`、`supervisor_stop`），8 秒没退才强制结束，不留下旧服务。`Stop-ScheduledTask` 停不掉它。

**其他**：默认要求加密配对（`--plain` 关掉）；外设接口只报告「订阅变化」不报告「连接」，所以以订阅心跳作为手机连上的标志；蓝牙关着时守护进程记 `radio_off`、每 10 秒再试；默认一直发 iBeacon（major 1、minor 1，`--no-beacon` 关掉）；排查卡死用 `py-spy dump --pid <PID> --native`。

## Mac 电脑端的要点

`prototype/mac_peer/`（Swift + `CBPeripheralManager`），用法见它的 `README.md`。规则、参数、日志的列和事件名和 Windows 端一样。

- **默认不加密**（`--secure` 打开）：iPhone 和 Mac 登录同一个 Apple 账户时，Mac 上记着的配对可能是 iCloud 同步来的，系统设置里看不到、没法忘记。一边丢了配对（比如在 iPhone 上忽略了这台 Mac）就再也配不上：iPhone 留着旧密钥时每次连接都加密失败；iPhone 忘记以后，Mac 直接拒绝配对请求。Mac 的蓝牙地址固定，不配对 App 也认得；登记了自动解锁以后，报告和解锁请求靠应用层 HMAC 认证。
- **空闲秒数**：`CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`，取键盘、鼠标各类事件里最小的。
- **锁屏状态**：`CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked`；用 `open` 启动时它可能是空的，就读 IORegistry 根节点的 `IOConsoleUsers`。
- **锁屏**：私有接口 `SACLockScreenImmediate`（login.framework），和菜单「锁定屏幕」一样，马上锁、不弹窗、不要辅助功能权限。**关屏**：`pmset displaysleepnow`（只关屏不睡眠，不要管理员权限）。**亮屏**：`IOPMAssertionDeclareUserActivity`。
- **不让系统空闲睡眠**：运行期间默认不让系统睡（显示器照样会关），否则人一走 Mac 睡了，手机回来时连不上；也避免 App Nap 拖慢定时器。`--allow-sleep` 关掉。
- **会报告取消订阅**：手机走远断开后约 2 秒就有 `unsubscribe`（Windows 上配对过的手机离开时从来不报），手机一走就停发心跳；停发、恢复的规则照 Windows，不试探。心跳用 `updateValue` 发，队列满时不补发（`hb` 的 note 写「发送队列满」）。
- 没有守护进程和看门狗（卡死是 WinRT 特有的问题）；登录自启（`autostart.sh`，LaunchAgent）时意外退出由 launchd 重启，只允许运行一份。Mac 发不出 iBeacon。

## 靠近自动解锁（应用层 v3）

只对明确登记过的电脑和手机生效：判断沿用上面的规则（真锁屏、走远过、明显靠近后电脑发状态 3），手机看到新的提示编号就自动发一次签名请求，不用每次在手机上确认。没登记的电脑行为不变（只弹通知，人自己输密码）。`--no-lock` 时不启用，Windows 可以用 `--no-auto-unlock` 临时关掉。

### 离线登记

- **Mac**：`MacPeer.app --setup-unlock`。先给辅助功能和发送系统事件的权限，在本机安全输入框填登录密码、本机验证；密码和 32 字节随机密钥只存本机钥匙串（不同步）。重新登记换新密钥，`--forget-unlock` 删除。
- **Windows**：`prototype/windows_unlock/manage.ps1 -Action Install -Enroll`（UAC 由本人批准），原生窗口问一次账户密码（不是 Hello PIN），密码存在只有 SYSTEM 和管理员读得到的地方；`-Action Export` 重新显示登记码；没有密码的账户走 `EnrollEmpty`，Windows 真的认证成功一次以后才启用。
- **手机**：电脑详情 →「靠近自动解锁」→「扫码登记」或粘贴。只存随机密钥，钥匙串 `AfterFirstUnlockThisDeviceOnly`（手机重启后要先解锁一次）。App 只认 `darwin + ax-hmac-v3`、`win32 + win-hmac-v3` 两组能力。
- 密钥不经过蓝牙。登记码就是能解锁这台电脑的密钥，别让别人拍到；换手机或怀疑泄露就在电脑上重新登记。

### 认证 REPORT

- 登记过的电脑只让 35 字节认证 REPORT 推动判断；6、7 字节的旧报告只维持心跳，不进判断（没导入登记的手机也能先连着，好完成登记）。
- 核对 `keyID`、签名、心跳 seq 新鲜（必须是本进程实际发出过的心跳，Windows 还要求是发给这条连接的；发出后 `max(10, 当前间隔 + 5)` 秒以内）、没重放（签名缓存保留 `max(10, 最长间隔 + 5)` 秒）。通过才回成功，同时给这条连接建立在场证明；没通过回 `0x08`，记 `report_auth_reject`（每 30 秒最多一行）。手机收到本会话的成功回复后才允许自动请求。iBeacon 唤醒的主动报告用同一个 seq、新的每包随机数。
- 断订阅就清掉这条连接的在场证明和挑战；Windows 底层链路断开也清（连这台手机的信号缓存一起），并在读写事件入队时记下连接代际，旧回调不能给重连后的连接建立证明。电脑端重启换新的 `reportNonce`，不恢复旧报告和提示。

### 挑战和解锁请求

- 每次读写实时核对：真锁着屏、正在提示同一个编号（手动解锁是锁着、没在提示，见「手动锁屏、解锁」）、真锁屏模式、登记仍有效（Mac 每次重读钥匙串）、**这条连接自己**有新鲜的认证报告。
- 随机数绑定读它的连接，**核对一次就作废**（不管对错），从提示开始 120 秒有效，提示撤销或状态变化就作废；同一次提示最多失败 3 次；不并发；别的连接不能占住或消费它。
- 成功回复只在**系统确认真的解锁以后**才发；系统没解开回 `0x83`，不自动重试密码，Windows 之后暂停自动解锁直到看到手动解锁。

### 手机端

- 每台电脑同一个 `reportNonce`、同一个提示编号只自动尝试一次，去重标记持久保存（电脑新进程的同编号可以再试）。读挑战到等回复期间有独立的后台任务，到期停掉没发的，已经发出的记「结果未确认」。失败、超时不自动重试，只有「发出后连接断了」补发一次。
- 手动解锁见「手动锁屏、解锁」。通知上的「解锁」要先解开手机（系统的 `.authenticationRequired`）。能删除登记、关掉自动；忘记这台电脑会删掉对应的钥匙串登记。

### 电脑怎么执行、日志

- **Mac**（`MacHost`）：只向当前 console 用户、同一个 audit session 的 loginwindow **安全密码框**写 `AXValue`（逐字符模拟键盘在锁屏界面上不行），按一次 Return，最多 7 秒确认系统真的解锁；普通输入框、焦点变了、权限不够或状态不确定一律失败。密码不进蓝牙、手机、日志或命令行。不装 root helper 或授权插件，不改系统认证策略。
- **Windows**：自带的 V2 Credential Provider（`prototype/windows_unlock/`）把本机凭据交给 Windows 认证，不模拟键盘；保留系统所有 Provider，能卸载。只支持本机管理员账户、已登录并锁着的本地控制台会话。`win_peer.py` 通过一次性签名的本机 IPC 发请求，Provider 核对调用者的 SID、会话和真实锁屏状态，不测距离。支持范围和安全边界见那里的 `README.md`。
- 电脑记 `unlock_enabled` / `unlock_disabled`、`unlock_request`、`unlock`（系统已确认解锁）、`unlock_fail`；只有系统确认才算成功，日志不记密码、密钥、签名包和登记码。
- HMAC 证明的是「这是登记过的那部手机」，不是距离；拿着你手机的人走到电脑前，电脑就可能解锁。不想要就关掉自动解锁或删除登记。

### 断线补发

手机回到电脑附近的头几分钟，手机和 Mac 的连接有时每十几秒就超时断开一次（手机就在旁边也一样，原因还不清楚），请求没送到就只能手动解锁，也碰到过电脑已经解锁、回复却没回来。所以 App 补发一次；电脑端不用改，本来就允许同一次提示里读新挑战再核对。

- 只补「签名请求已经发出、等回复时连接断了」（链路断开或电脑端服务变了）。电脑回了失败、连着但 30 秒没回复、后台时间用完、改了登记或关了自动，都不补。
- 重新连上、读完 INFO、本连接的认证报告通过以后，电脑还在请同一次提示（状态 3、编号相同）、`reportNonce` 没变、离第一次发出不到 120 秒，就读新挑战、用新签名补发一次。每次提示最多补一次；手动确认过的补发不再要 Face ID。不补记 `unlock_retry_skip` 和原因；补发状态只在内存里，App 被结束就不补。
- 不会重复解锁：旧签名不能重放；第一次已经到了、电脑正在执行时不给新挑战（`0x80`）；解锁了就不是状态 3。
- 日志 `unlock_retry`（note 写第一次发出后几秒）、`unlock_sent`「已补发一次签名请求」。电脑详情「诊断」里的「测试：下次解锁请求假装断线」让下一次请求不发、直接断开（`unlock_test`），用来测补发。

### 手动锁屏、解锁

App 首页每台电脑右边有一个锁按钮，显示电脑锁没锁：锁着时点一下解锁，没锁时点一下锁屏。**不要 Face ID**：能打开 App 说明手机已经解开了，和自动解锁一样直接发签名请求。用得上的是「回来了但没提示」的时候：走开不到 1 分钟、信号没比走远时强 10 dB、自动解锁后又被系统锁回去。

- **INFO**：登记了解锁、支持这一节的电脑端写 `"manual": 1`。App 看到它才在「已锁屏」（状态 2）时让按钮能解锁、在「未锁屏」时让按钮能锁屏；没有（旧电脑端）就照旧，只在请提示时能解锁，按钮是灰的。
- **手动解锁**：复用 CHALLENGE / UNLOCK，字节格式和签名不变，**提示编号用 0**。
  - 电脑真的锁着、没在请提示、这条连接有新鲜的认证报告时，读 CHALLENGE 回编号 0 和新随机数；在请提示时照旧回当前编号。编号 0 的签名解不了提示，提示的签名也解不了编号 0。
  - 随机数从发出起 30 秒有效（按提示解锁是从提示起 120 秒），只给读它的那台手机，核对一次就作废；过期了再读就换一个。失败次数和提示的分开算，每次锁屏最多 3 次，电脑真解锁以后才清零（手机断开再连回不清）。
  - 解锁走的和自动解锁同一条路；判断那边看到的是「没提示就解锁了」，手机信号弱时照样会进 `lock_hold`。
  - Mac 读挑战时先点亮屏幕（记 `display_on`「手机要手动解锁」，`--no-wake` 时不点亮）：屏幕关着或在放屏保时，登录界面的密码框要亮了才出来。Windows 不点亮：Credential Provider 不用等密码框，解锁本身会把电脑从待机里叫醒；`--screen dim` 调暗过的先恢复亮度（`undim`）。Windows 系统解锁失败一次就连手动解锁一起停，直到在电脑上解开，免得反复提交错误密码把账户锁定。
  - App：首页锁按钮、详情页「现在解锁这台电脑」都走这里。电脑在请提示就按这次提示解，只是锁着就用编号 0；签名前再核对电脑还是「锁着、没在请提示」，状态变了就取消。断线补发照样适用（重新连上后电脑还锁着、没在请提示就补发）。通知上的「解锁」带着提示编号，不走编号 0。
- **锁屏（LOCK）**：格式见「数据格式」。
  - 电脑核对：这条连接有新鲜的认证报告；`keyID` 是本机登记的；`seq` 是这次进程真发过、没过期的心跳（和认证 REPORT 一样，Windows 还要求是发给这条连接的）；签名对；包没重放过。锁屏只会让电脑更安全，所以不读挑战、不限失败次数。本来就锁着也回成功。
  - Mac 用 `SACLockScreenImmediate` 锁屏，2 秒后关显示器（`--keep-display` 不关）。Windows 用 `LockWorkStation`，**不主动关屏**：电脑端关屏进的待机会把电脑端冻住（见「Windows 的现代待机和电源请求」），之后手机上点解锁就没人应答；只锁屏的话，锁屏界面约 30 秒后系统自己关屏，进的是闲置待机，电脑端照常跑，手机随时能解锁。
  - 判断那边当作用户自己锁的屏：手机一直在旁边就不会请提示，回到电脑前要在手机上点一下解锁，或者带着手机走开 1 分钟以上再回来（照常请提示、自动解锁）。
- **日志**：电脑端 `unlock_request` / `unlock` / `unlock_fail` 的 note 带「手动解锁」；锁屏 `phone_lock`（「已锁屏」或「本来就锁着」）、`phone_lock_reject`（原因）、`phone_lock_fail`。App `unlock_manual`（用户点了解锁，写是按提示还是手动）、`lock_sent` / `lock_result`。

### 登记确认（ENROLL_ACK）

手机扫码或粘贴保存登记以后写一次 ENROLL_ACK（格式见「数据格式」，绑定这条连接读到的 `reportNonce`），电脑上的登记窗口显示「已收到 iPhone 确认，即将关闭」、清掉二维码和 JSON 后自己关。**只用来关窗口**：不算在场、不参与判断、不能解锁，重放也只会再关一次窗口。

- 手机：保存成功时连着这台电脑、读过 INFO 就写一次；没连着就等下次读完 INFO 补发，保存 2 分钟以后不补（窗口多半早关了）。电脑没有这个特征就不发；不重试，电脑回 `0x81` 只记日志，登记照样保存。日志 `enroll_ack_sent` / `enroll_ack_ok` / `enroll_ack_fail` / `enroll_ack_skip`。
- 电脑：`keyID` 和载入的不一样（刚重新登记）就现读本机登记再验。验过记 `enroll_ack`、通知登记窗口（Windows 用命名事件 `Local\iphone-proximity-unlock-enroll-ack`，Mac 用 Darwin 通知 `com.proximity-unlock.mac.enroll-ack`）；验不过回 `0x81`、记 `enroll_ack_reject`。Mac 第一次登记时后台电脑端还没有密钥、不开这个特征，窗口要手动点「完成」。

### 手机请求显示登记码（ENROLL_REQUEST）

在 App 里点「扫码登记」时，App 顺着已有的连接写一次 `0x01`、同时打开相机，电脑自己弹出登记窗口，不用再去电脑上敲命令。**电脑上先确认再显示二维码**：二维码就是能解锁这台电脑的密钥，Mac 的连接默认不加密，附近任何设备都能写这个特征；不先问的话，别人可能趁电脑开着把码弹出来拍走，远程控制或录屏时也会被录进去。

- 有没有登记都开放。回复：成功 = 弹出了确认窗口（或者已经开着）；`0x81` = 电脑锁着屏；`0x82` = 弹不出窗口；内容不对回 `0x0D`。App 在扫码页顶上照着提示；电脑没有这个特征（旧版）时提示去电脑上打开登记窗口。
- 电脑端：窗口已经开着或 3 秒内刚弹过就直接回成功；弹窗在单独的进程里（Mac 另起 `MacPeer.app --setup-unlock --phone-request`，Windows 另起 `prototype/enroll_prompt.py`），不卡蓝牙和心跳。确认窗口写明「有 iPhone 通过蓝牙请求登记」，默认按钮是「不用」。已登记的选「显示二维码」显示现有登记码（不换密钥、不要密码）；没登记时 Mac 能走本机登记，Windows 只提示用管理员身份运行 `manage.ps1 -Action Enroll`，不静默提权。后台起的窗口系统不让它抢到最前面，所以两边都把确认窗口设成置顶。
- 日志：电脑端 `enroll_request` / `enroll_request_reject`（note 写原因），App `enroll_request_sent` / `enroll_request_ok` / `enroll_request_fail`。

## 用 iBeacon 拉起 App（实验）

**要解决的问题**：App 在多任务界面被划掉、手机重启以后，蓝牙后台恢复管不到，人回来 App 也不会连电脑。iBeacon 区域监测在这两种情况下也会把 App 在后台拉起来（要「始终」定位权限、打开「精确位置」；重启后要先解锁过一次手机）。苹果 DTS 在开发者论坛上说区域监测是少数能拉起被划掉的 App 的例外；有人在 iOS 18 上测 50 次成功 43 到 48 次，也有人报告 iOS 26 上不灵了。我们是在 iOS 18 上测的。

**格式**：UUID `9E698AEC-9C56-46E3-9209-F2628704D932`（App 只按 UUID 监测），major 1 = Windows、2 = Mac，minor 先都用 1，1 米处信号 -59。

**App**（`BeaconWatcher.swift`）：有「始终」权限就登记区域（系统一直记着，重装也在），进出区域、在区域里亮屏（`notifyEntryStateOnDisplay`）都会报，被拉起时多要 20 秒后台时间；前台时测距，「工具与记录」→「iBeacon 唤醒（实验）」显示信号，区域事件可以弹测试通知。被区域事件拉起时 launchOptions 里不一定有定位（实测是空的），所以启动 2 秒内、还没到过前台时收到的区域事件（自己 `requestState` 的回复不算）记 `launch_reason`：进入、离开算确定；「状态」事件只写「可能」，因为别的原因启动时刚好亮屏也会送。

**Mac 发不出去**（macOS 15 上实测）：私有键 `kCBAdvDataAppleBeaconKey` 系统照收、不报错，但手机一直收不到。bluetoothd 把第三方 App 的厂商数据并进 0 号可连接广播，和系统自己一直在发的接力 / 附近信息抢同一个位置，放不下两份 Apple 厂商数据，系统留自己的。和服务 UUID 放一起、分两个 manager、`kCBAdvDataIsConnectable = false`、普通厂商数据键都试过，都不行。所以 Mac 要么靠同一张桌上的 Windows 发，要么放一个能改 UUID 的 iBeacon 小标签。`prototype/mac_beacon/` 留着备查。

**Windows 能发**：`win_peer.py` 和实验工具 `prototype/win_beacon.py`（能轮流开、停，记 CSV）用 `BluetoothLEAdvertisementPublisher` 发厂商数据 0x004C，和协议服务同时发互不影响。`win_beacon.py --on 60 --off 60` 轮流发时划掉 App，停发约 30 秒后的「离开区域」事件把 App 拉起（不是「进入区域」），0.1 秒内重新订阅。也就是说，在电脑前划掉 App 不会马上被拉起，人一离开、iOS 报离开区域就会拉起，回来时 App 已经在跑。手机重启后能不能被拉起还没测。

**测法**：1. App 前台看到 iBeacon 的信号。2. App 在后台、手机锁屏：停发 1 分钟再发，看 `beacon_exit`、`beacon_enter`。3. 划掉 App、锁屏：停发 1 分钟再发，看有没有测试通知、`app_launch` 和 `launch_reason`，拉起后有没有连上电脑，多做几次。4. 重启手机、解锁一次后再做第 3 步。

## 日志 CSV

三边都把事件记到 CSV，列相同：

```
time, t, event, seq, rssi, phone_state, latency_ms, device, note
```

`time` 是墙上时钟（ISO 格式，到毫秒），`t` 是从起点算起的秒数。UTF-8 带 BOM，每行立刻写盘。`link_analyze.py` 按 `time` 对齐手机和电脑端的日志，两台设备的时间要准。

### 电脑端

- 文件：Windows `peer_日期_时间_win32.csv`，工作进程重启后接着写同一个，`t` 从守护进程启动算起；Mac `peer_日期_时间_darwin.csv`，每次启动换一个（登录自启时在 `~/Library/Logs/proximity-unlock/`）。
- `report` 的 `latency_ms` 是**往返延迟**（发出心跳到收到这次报告）。`device`：Windows 写手机名和蓝牙地址，Mac 写 `手机（identifier 前 8 位）`。
- 连接和心跳：`start`、`stop`、`subscribe` / `unsubscribe`、`device`（Windows）、`read_info`、`report`（认证报告 note 写 `auth=v3`）、`bad_report`、`report_auth_reject`、`hb`（note 写发给了几台、耗时）、`hb_pause` / `hb_resume`、`hb_rate`、`adv_status`。
- 只有 Windows：`app_proto`、`link`、`radio`、`adv_retry` / `adv_ok`、`beacon_on` / `beacon_status` / `beacon_retry`；守护进程记 `stuck`、`worker_exit`、`radio_off`、`supervisor_resume`、`supervisor_stop`、`adv_repair` / `adv_repair_done`。只有 Mac：`bt_state`、`add_service_error`、`restore_reports`。
- 判断：`judge`（note 像 `away idle=75s lost`）、`lock` / `would_lock`、`lock_skip`、`lock_hold`、`lock_resume`、`locked` / `unlocked`、`prompt` / `would_prompt`、`prompt_cancel`、`back`、`judge_restore`、`phone_known`。
- 屏幕和电源：`display_off`、`display_on`（Mac）、`dim` / `undim`（Windows，note 带 `brightness=原亮度`）、`keep_awake` / `allow_sleep`（Windows）。
- 自动解锁和登记：`unlock_enabled` / `unlock_disabled`、`unlock_request`、`unlock` / `unlock_fail`、`enroll_ack` / `enroll_ack_reject`、`enroll_request` / `enroll_request_reject`。

### 手机端

- 文件 `phone_日期_时间_ios.csv`。系统在后台重新拉起 App 时接着写同一个，用户点「新建记录」才换，所以 `t` 从文件创建算起。日志很大时导出容易出问题，可以先「新建记录」。
- `device` 列是 `电脑名（identifier 前 8 位）`，比如 `DESKTOP-ABC123（3F2A9C01）`，几台电脑的事件混在一个文件里；还不是记住的电脑写 `未知（前 8 位）`；不分电脑的事件是空的。`link_analyze.py` 用 `--device` 选一台。
- `report`：每次心跳一行，`latency_ms` 是**从收到心跳到读到 RSSI** 的毫秒数，note 写「漏了 N 次心跳」「电脑端可能重启了」。`skip`（较早那次心跳不回）、`state`（手机判断变了）、`label`（位置标记，note 是 `名称:类别`，类别同 `rssi_probe.py`）。
- 连接：`connect_request`、`connect`、`connect_fail`、`encrypt_retry`、`disconnect`、`subscribe`、`info`、`reconnect`（用户点了「重新连接」）、`pairing_problem`。
- 等服务：`service_changed`、`no_service`、`service_back`、`no_service_drop`（30 秒没回来，主动断开）、`no_service_wait`（断开后马上又连上，之后不再断）。
- 看门狗和休眠：`hb_timeout`、`hb_back`、`hb_interval`、`report_wake`（列和 `report` 一样）。旧服务：`service_dup`、`service_switch`、`stale_service`、`link_problem_notify`、`stale_resolved`。
- 搜索和添加：`scan_start`、`scan_stop`、`found`、`add`、`forget`、`candidate`、`candidate_connect`、`candidate_reject`、`adopt`（note 写旧 → 新 identifier）。
- App 和系统：`app_launch`（区分用户打开和系统后台唤醒）、`settings`、`restore`、`bt_state`、`app_active`、`app_background`、`phone_locked` / `phone_unlocked`。
- 提示：`host_state`（电脑状态或提示编号变了）、`prompt_shown`、`prompt_removed`、`prompt_error`、`prompt_tapped`、`notify_auth`、`prompt_test`。
- 自动解锁：`unlock_auto_attempt`、`unlock_auth`（手动确认）、`unlock_sent`、`unlock_result`、`unlock_retry` / `unlock_retry_skip`、`unlock_test`。登记：`enroll_ack_sent` / `enroll_ack_ok` / `enroll_ack_fail` / `enroll_ack_skip`、`enroll_request_sent` / `enroll_request_ok` / `enroll_request_fail`。
- iBeacon（不分电脑）：`launch_reason`、`beacon_setup`、`loc_auth`、`beacon_monitor`、`beacon_state`、`beacon_enter`、`beacon_exit`、`beacon_range`（前台测距，最多 5 秒一行）、`beacon_error`。

## 实现

- Windows 电脑端：`prototype/win_peer.py`（Python + WinRT），自动解锁组件 `prototype/windows_unlock/`。
- Mac 电脑端：`prototype/mac_peer/`（Swift + CoreBluetooth），用法见它的 `README.md`。
- iPhone：`ios/`（SwiftUI + CoreBluetooth），用法见 `ios/README.md`。
- 改协议时三边一起改，并同步更新这份文档。
