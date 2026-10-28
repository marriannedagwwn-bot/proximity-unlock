# Windows 本机自动解锁组件

最小 V2 Credential Provider + 普通用户 BLE 后台适配。支持 **Windows 10/11 x64、本机管理员账户、当前已登录且已锁定的本地控制台会话**。首次开机登录、标准用户经另一个管理员代登、Microsoft/AD/Entra 账户、RDP、切换到其他用户均不支持。Windows Hello PIN 不是账户密码。现有空密码账户只能走明确确认的 `EnrollEmpty` 暂存和真实控制台认证验证路径；程序不设置/更改密码或降低空密码限制策略。

`manage.ps1` 只注册本项目的 Provider，不安装过滤器，不禁用或替换系统密码/PIN/Hello Provider。用户始终可用系统入口手动解锁。当前自建 DLL 尚未做发布签名；构建成功和未登记拒绝测试不等于真实锁屏验收。

## 构建和不锁屏验证

在 x64 Visual Studio C++ 开发命令行（需 Windows SDK）中：

```powershell
./prototype/windows_unlock/build.ps1
```

也支持可删除的便携 Zig 0.14.1 C++ 工具链，不安装系统服务或编译器。磁盘紧张时把工具链、临时目录和缓存放到有空间的磁盘：

```powershell
$env:TEMP = 'D:\ProximityUnlockBuild\temp'
$env:TMP = $env:TEMP
$env:ZIG_GLOBAL_CACHE_DIR = 'D:\ProximityUnlockBuild\cache'
$env:ZIG_LOCAL_CACHE_DIR = 'D:\ProximityUnlockBuild\local-cache'
./prototype/windows_unlock/build.ps1 -ZigPath 'D:\ProximityUnlockBuild\zig\ziglang\zig.exe'
```

构建脚本产出忽略的 `build/ProximityCredentialProvider.dll`、`ProximityUnlock.exe` 和 `NativeTests.exe`，随后执行本机验证：RFC 4231 HMAC 固定向量、用户 DPAPI 往返和篡改拒绝、非真实密码的 KERB 序列化布局/偏移和 CredProtect、本机控制台 SID/会话门禁、直接装载真实 DLL 并调用 COM 工厂/不支持场景/未登记零凭据、卸载重载。它不会登记 Provider、读取真实密码、提交登录凭据或锁屏。

Python 后端验证：

```powershell
$env:PYTHONPATH = 'prototype'
./.venv/Scripts/python.exe -m unittest windows_unlock.test_backend -v
```

## 安装、登记和撤销

先检查源码、构建输出和 SHA256，然后运行：

```powershell
./prototype/windows_unlock/manage.ps1 -Action Install -Enroll
```

若需要提权，脚本通过 Windows UAC 请求。**UAC/管理员批准必须由用户本人处理。** 登记必须以当前已解锁控制台的同一个本机管理员账户运行。接着原生 Windows 凭据窗口只询问一次账户密码，`LogonUser` 只用于登记验证，不当作解锁结果。取消或验证失败不会自动重试。密码不能放在聊天、命令行或文件中。

如果当前本机账户本来就没有密码，使用下面的专用入口，而不在普通密码窗口猜测输入。原生确认窗口明确显示当前账户并默认选“否”，明确说明只做 provisional 暂存，等待真正的 Windows 控制台认证验证。空密码账户调用 `LogonUserW(..., L"", LOGON32_LOGON_INTERACTIVE, ...)` 在默认的 `LimitBlankPasswordUse=1` 下会返回 `ERROR_ACCOUNT_RESTRICTION`（1327）；这不是空密码已验证的证据，专用路径不调用它，也不靠错误码启用手机能力。`LimitBlankPasswordUse` 保持原值；此路径不增加 RDP/远程支持，也不更改账户密码。

```powershell
./prototype/windows_unlock/manage.ps1 -Action Install -EnrollEmpty
# 组件已更新后，也可只登记：
./prototype/windows_unlock/manage.ps1 -Action EnrollEmpty
```

暂存会生成随机密钥并写入 DPAPI，但把 `VerifiedKeyId` 置零。此时 `status` 返回 `pendingValidation:true, available:false`，Python `load_backend()` 返回 `None`，手机 JSON 窗口也拒绝显示。只有直接在本机调用一次 helper 的 `request`，让 Provider 提交当前 SID 的空凭据、收到 Windows `ReportResult(status=0, substatus=0)`，才由 SYSTEM 写入与同一 keyID 绑定的验证标记。验证前重读机器登记并在与登记/删除共用的可信 mutex 下检查 generation；旧请求不能验证新密钥。若 Windows 不回成功回调，则保持未验证。单独的手动解锁、IPC ACK 或 1327 都不会启用登记。

本机 helper 仍须观察到同一 SID/会话的真实 WTS 解锁才返回 `success:true`；取得回调与验证标记本身不当作实际解锁结果。确认后运行 `Status`，然后 `Export` 才能在窗口中取得手机 JSON，最后重启 BLE 后台。空密码能不能真的解锁，要在每台电脑上实际验证，不能从自测通过推断。

Provider 对空密码使用与微软示例一致的零长度 KERB Password 字段，CPUS_LOGON 和 CPUS_UNLOCK_WORKSTATION 都不把空字符串送入 CredProtect。原生测试覆盖这两种布局；它们仅证明编码正确，不能代替空密码账户的真实 Windows 验证和锁屏解锁验收。

登记后原生窗口显示可选择的离线 JSON，格式与 Mac v3 一致，只含 32 字节随机手机密钥和 keyID。没有蓝牙 KEY 特征，也不写明文转移文件。将 JSON 导入 iPhone App 的对应电脑；如自行复制，完成后清除剪贴板。窗口在 JSON 上面同时显示同一段 JSON 的二维码（纠错 M、白底、四周留 4 格），在 App 电脑详情里点「扫码登记」/「扫码更新登记」扫它即可，不用复制；二维码只在内存里画，不存文件、不进剪贴板，关窗口时清零。二维码用 vendored 的 Nayuki QR Code generator v1.8.0（`native/qrcodegen.*`，MIT，未修改），只编进 helper，不进 Provider DLL；helper `selftest` 会检查最长的登记 JSON 编出 41×41（版本 6）的码。窗口开着时建命名事件 `Local\iphone-proximity-unlock-enroll-ack`；手机保存登记后发来的确认（`docs/protocol.md`「登记确认」）由 `win_peer.py` 验签后设这个事件，窗口显示「已收到 iPhone 确认，即将关闭」、清掉二维码和 JSON，2 秒后自己关；没收到确认就照旧手动关。手机不会得到 Windows 密码。登记或更新密码后重启 BLE 后台。

```powershell
./prototype/windows_unlock/manage.ps1 -Action Status
./prototype/windows_unlock/manage.ps1 -Action Export             # 本机窗口重新显示手机登记内容
./prototype/windows_unlock/manage.ps1 -Action Enroll             # 更新密码并轮换两把随机密钥
./prototype/windows_unlock/manage.ps1 -Action RemoveEnrollment   # 立即禁用并删除本机登记
./prototype/windows_unlock/manage.ps1 -Action Uninstall          # 撤销注册，保留所有系统 Provider
```

卸载先删除本项目两处注册表项，然后清理加密登记与二进制。若 DLL 正被 LogonUI 使用，需手动正常解锁/注销或重启后再删除 `C:\Program Files\ProximityUnlock\ProximityCredentialProvider.dll`。不用修改 Windows 登录策略或系统服务。手机导入的旧密钥在本机删除/轮换登记后失效。

## 本机安全边界

- `%LOCALAPPDATA%\ProximityUnlock\enrollment.bin` 是用户 DPAPI，只含手机随机密钥、独立 IPC 随机密钥、keyID 和账户 SID，文件 ACL 仅目标用户和 SYSTEM。普通 BLE 进程不读取账户密码。
- `%ProgramData%\ProximityUnlock\enrollment.bin` 是机器 DPAPI，含密码与上述登记。目录和文件的 owner 固定 Administrators，DACL 仅 SYSTEM 和 Administrators。机器 DPAPI 本身允许本机用户解密，因此**目录/文件 ACL 与可信 owner 是必要保护**。登记拒绝普通用户预先占有或 reparse 的机器目录。管理员/SYSTEM 属于本机受信任边界。
- Provider 只在 SYSTEM LogonUI、明确 CPUS_LOGON/CPUS_UNLOCK_WORKSTATION、目标 SID 在用户数组中、当前活动控制台会话已登录且真实锁定时服务。每次序列化前重新核对，不能凭 CPUS 枚举推断已锁屏。
- IPC 是每会话首实例命名管道，ACL 只允许 SYSTEM 和目标用户，拒绝远程；服务端检查实际客户端 token SID/session。客户端限制服务端只能使用 Identification 级别身份模拟。
- Provider 发出 2 秒、随机 nonce、绑定 SID/session/keyID 的 HMAC 挑战；客户端先验服务端 HMAC，再以独立 IPC 密钥签请求。每条连接只接受一次并在读密码前消费；过期、重放、错误签名、错误 SID/session、非控制台、并发请求均不能序列化。没有接受裸 `unlock` 命令的本机服务。
- 接收 IPC 只表示请求接受，`CPGSR_RETURN_CREDENTIAL_FINISHED` 只表示提交给 Windows 验证。普通用户 helper 只有观察到同一 SID/会话的真实 WTS 解锁状态才返回成功，否则超时返回未确认。Python 最多等待 6.8 秒，一次请求，无密码重试；Provider 同一生命周期只序列化一次。失败后 BLE 后台保持失败锁存，直到观察到手动解锁。
- LogonUI 事件通过 Advise 线程的消息窗口派发；工作线程不调用跨 apartment 的 COM 指针。凭据、临时 DPAPI 明文、IPC 密钥和本机窗口 JSON 用后清零；Python/OS 对随机密钥的内存副本不承诺完全清除。

## 本机诊断与交互验收

`ProximityUnlock.exe setup-status` 只读取状态，不弹窗、不认证，也不保存登记。它输出管理员/提升状态、当前与控制台 session 是否一致、SID 是否匹配及 WTS 锁屏查询结果；普通用户进程的 `administrator:false` 属于正常结果。登记时仅在其余身份与管理员门槛均通过后，最多等 5 秒让短暂的锁态过渡结束，仍必须实际处于解锁状态。

真实 `request` 输出固定阶段和 Win32 数字错误。SYSTEM Provider 还在本组件自己的配置键保留有界诊断，可只读查看：

```powershell
Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\ProximityUnlock' |
    Select-Object Diagnostic* | ConvertTo-Json
```

阶段记录包括使用场景、用户数组匹配、管道就绪、请求接受、序列化和 Windows 认证回调，只含固定名称、PID、session、单调时间及数字结果，不记录 SID、账户密码、密钥、挑战或请求字节。判断测试结果时核对本次 PID 和时间，避免把旧进程的阶段当作本次成功。管道探测使用 `WaitNamedPipe`，不要打开连接消耗一次服务。

安装/登记由用户处理 UAC 和本机密码输入或现有空密码的明确确认；本机自动化不得代替批准。登记后先运行 `ProximityUnlock.exe status` 确认目标账户可用。可由普通用户后台在测试锁屏后仅调用一次 `request`，核对 WTS 真正解锁以及系统手动密码/PIN路径仍可用。错误密码的单次提交与失败锁存、删除登记、换密钥、切换用户、注销、非目标会话都需分别记录结果。这个 `request` 会执行真实本机解锁，不能拿自测通过代替它。

空密码登记验收时应看到：暂存时不可导出、不可启用 BLE；锁屏后等本次用户匹配与管道就绪，只发一次请求，确认同一控制台已解锁；该 Credential 的 Windows `ReportResult` 主/子状态均为零，SYSTEM 随后设置验证标记，最终 `available:true, pendingValidation:false, locked:false`。**有密码账户的真实登记、错误密码、其他账户等交互场景还没有真机验证记录**，使用前先在自己的电脑上按上面的方法验收。

完整 BLE 靠近链路要把 iOS App 用 Xcode 签名编译、装到 iPhone 以后再验收：走远锁屏、靠近无需确认解锁，以及手机锁屏后台、重启和断连等。原生登记可用后，认证模式会拒绝旧 App 的无签名报告用于靠近/离开判断；先装新版 App、导入密钥，再验收这条链路。

实现参考微软 [V2 Credential Provider 示例](https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/CredentialProvider)、[GetSerialization](https://learn.microsoft.com/en-us/windows/win32/api/credentialprovider/nf-credentialprovider-icredentialprovidercredential-getserialization)、[Windows 10 场景合并](https://learn.microsoft.com/en-us/windows/win32/api/credentialprovider/ne-credentialprovider-credential_provider_usage_scenario)、[DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)、[保留系统 Provider](https://learn.microsoft.com/en-us/windows/win32/secauthn/credential-providers-in-windows)。
