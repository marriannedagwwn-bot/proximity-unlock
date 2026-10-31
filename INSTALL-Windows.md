# Windows 电脑端安装说明

`ProximityUnlock-<版本>-Windows-x64.zip` 里是 Windows 电脑端（Python 脚本）和自动解锁组件（编译好的 Credential Provider 和登记工具）。iPhone App 另外装，见项目 README。

## 先看清楚

- **系统**：Windows 10/11 x64，蓝牙要支持 BLE 外设模式（电脑当外设让 iPhone 连）。要装 Python 3.12 x64。
- **自动解锁只支持**：本机管理员账户、已经登录并且锁着的本地控制台会话。不支持开机后第一次登录、标准用户、Microsoft / AD / Entra 账户、远程桌面、切换用户。Windows Hello 的 PIN 不是账户密码。详见 `prototype/windows_unlock/README.md`。
- **有密码账户的登记和自动解锁还没有在真机上验证过。** 用之前先在自己的电脑上试：登记后锁屏，带着手机走开再回来，确认能解开；也确认系统自己的密码 / PIN 照样能用。
- `ProximityUnlock.exe`、`ProximityCredentialProvider.dll`、`NativeTests.exe` **没有代码签名**，SmartScreen 或杀毒软件可能会拦。下载后对一下 Release 里 `SHA256SUMS.txt` 的校验值；不放心就从源码自己编（`prototype/windows_unlock/build.ps1`）。
- 这是原型。登记以后，拿着你手机的人走到电脑前，电脑就可能自动解锁。

## 1. 装 Python 和依赖

1. 自己装 Python 3.12 x64（python.org，或者 `winget install Python.Python.3.12`），装的时候带上 `py` 启动器。
2. 把 zip 解压到一个固定的位置，比如 `C:\ProximityUnlock`。之后别挪：登录自启的任务记着这个路径。
3. 在这个目录里打开 PowerShell：

```powershell
py -3.12 -m venv .venv
.venv\Scripts\python -m pip install -r requirements-windows.txt
```

## 2. 试跑一下（不锁屏）

```powershell
.venv\Scripts\python prototype\win_peer.py --no-lock
```

在 iPhone App 里点「+」添加这台电脑，第一次连接时按提示在 iPhone（和 Windows）上确认配对。终端里开始每秒出现手机的报告就可以了，按 Ctrl+C 退出。

## 3. 装自动解锁组件、登记（要管理员）

```powershell
powershell -ExecutionPolicy Bypass -File prototype\windows_unlock\manage.ps1 -Action Install -Enroll
```

- 会弹 UAC，自己点。
- 安装前先在本机跑一遍原生自检（`NativeTests.exe`），过了才装。只注册本项目的 Credential Provider，不动系统的密码、PIN、Hello，系统的解锁方式一直能用。文件装到 `C:\Program Files\ProximityUnlock`。
- 登记时弹 Windows 的凭据窗口，输一次这个账户的密码。密码只用来验证，用 DPAPI 存在本机，不会给手机。
- 登记完成的窗口里有二维码：在 iPhone App 的电脑详情里点「扫码登记」扫它。二维码就是解锁这台电脑的密钥，别让别人拍到。
- 账户本来没有密码的，见 `prototype/windows_unlock/README.md` 里的 `EnrollEmpty`。

以后要重新显示二维码：`manage.ps1 -Action Export`；换密码或换密钥：`-Action Enroll`；删掉登记：`-Action RemoveEnrollment`。

## 4. 登录时自动启动

```powershell
powershell -ExecutionPolicy Bypass -File prototype\install_autostart.ps1
Start-ScheduledTask -TaskName IphoneProximityUnlock-WinPeer
```

以后每次登录都会在后台启动电脑端，日志在 `logs\`。停止：`install_autostart.ps1 -Stop`。

## 用起来要知道的

- 走开：60 秒没碰键盘鼠标，并且手机失联或信号弱，就锁屏、关屏。回来：手机信号明显变强就请手机解锁，登记过就自动解开。走开不到 1 分钟就回来，不会自动解锁。
- 默认锁屏后马上关屏（`--screen off`）。支持现代待机的笔记本因此进了待机、或者合了盖以后，电脑端会被冻住，回来要先按一下键或电源键，之后手机连着就会自动解锁。
- 手机连着时重启电脑端，Windows 的蓝牙广播可能会坏（App 里重新添加时搜不到这台电脑）。按这个顺序重启：`install_autostart.ps1 -Stop`，再 `.venv\Scripts\python prototype\bt_toggle.py --settle 0`（关开一次蓝牙），然后马上 `Start-ScheduledTask -TaskName IphoneProximityUnlock-WinPeer`。
- 手机每 30 秒断开一次、关开蓝牙也不好时，重启 Windows。
- 规则和参数见 `docs/protocol.md`（在 GitHub 上），`win_peer.py --help` 列了所有参数。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File prototype\install_autostart.ps1 -Uninstall
powershell -ExecutionPolicy Bypass -File prototype\windows_unlock\manage.ps1 -Action Uninstall
```

然后删掉解压的目录。iPhone App 里删掉这台电脑，Windows 的蓝牙设置里删掉 iPhone 的配对。DLL 正被锁屏界面用着时删不掉，正常解锁或重启后再删 `C:\Program Files\ProximityUnlock\ProximityCredentialProvider.dll`。

---

**English**: Windows peer for Proximity Unlock. Requires Windows 10/11 x64 with BLE peripheral support and Python 3.12 x64. Unzip to a fixed folder, run `py -3.12 -m venv .venv` and `.venv\Scripts\python -m pip install -r requirements-windows.txt`, try `prototype\win_peer.py --no-lock`, then install the Credential Provider and enroll with `prototype\windows_unlock\manage.ps1 -Action Install -Enroll` (UAC; local administrator account on the local console only) and scan the QR code in the iPhone app. `prototype\install_autostart.ps1` starts the peer at logon. The native binaries are not code-signed. Enrollment and auto-unlock for accounts with a password have not been verified on real hardware yet; test it on your own PC first.
