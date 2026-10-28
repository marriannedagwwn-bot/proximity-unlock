# 开机自启：在任务计划程序里加一条"登录时在后台启动 win_peer.py"的任务（pythonw.exe，没有窗口）
#   安装：powershell -ExecutionPolicy Bypass -File prototype\install_autostart.ps1
#   卸载：powershell -ExecutionPolicy Bypass -File prototype\install_autostart.ps1 -Uninstall
#   停止后台的电脑端（不删任务，下次登录还会启动）：… -Stop；再启动：Start-ScheduledTask -TaskName IphoneProximityUnlock-WinPeer
#   注意 Stop-ScheduledTask 停不掉它：任务只管最外层的 pythonw，守护进程和工作进程会留下来
# 日志在项目的 logs 文件夹：peer_*.csv 是事件，win_peer_console.log 是原来打印到终端的内容
param([switch]$Uninstall, [switch]$Stop)
$ErrorActionPreference = "Stop"
$name = "IphoneProximityUnlock-WinPeer"
$root = Split-Path -Parent $PSScriptRoot

function Get-PeerProcs {
    @(Get-CimInstance Win32_Process -Filter "Name like 'python%'" | Where-Object { $_.CommandLine -match 'win_peer\.py' })
}

function Stop-Peer {
    # 先请它正常退出（停广播、撤服务）：直接强制结束的话，实测下次启动协议广播一直 ABORTED，要关开一次蓝牙才好
    $graceful = $false
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting("Local\iphone-proximity-unlock-win-peer-stop")
        [void]$ev.Set()
        $deadline = (Get-Date).AddSeconds(12)
        while ((Get-Date) -lt $deadline -and (Get-PeerProcs).Count -gt 0) { Start-Sleep -Milliseconds 300 }
        $ev.Close()
        $graceful = (Get-PeerProcs).Count -eq 0
    } catch { }
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    $procs = Get-PeerProcs
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($graceful) { Write-Host "电脑端已正常退出。" }
    elseif ($procs.Count -gt 0) { Write-Host "电脑端没有正常退出，强制结束了 $($procs.Count) 个进程。" }
    else { Write-Host "电脑端没在运行。" }
}

if ($Stop) { Stop-Peer; return }
if ($Uninstall) {
    Stop-Peer
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "已删除开机自启任务 $name。"
    return
}

$pythonw = Join-Path $root ".venv\Scripts\pythonw.exe"
if (-not (Test-Path $pythonw)) { throw "找不到 $pythonw，先在项目里建好 .venv 并 pip install bleak" }
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $pythonw -Argument "prototype\win_peer.py --log-dir logs" -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
# 用电池也跑、不限运行时长、意外退出后每分钟重启一次（最多 3 次）、已经在跑就不再开第二份
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -StartWhenAvailable
# 以当前用户、普通权限在登录会话里运行：锁屏、调亮度、蓝牙都要在用户会话里做
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "iPhone 靠近解锁：Windows 电脑端（prototype\win_peer.py），登录时在后台启动" -Force | Out-Null
Write-Host "已添加开机自启任务 $name：每次登录后在后台启动电脑端，日志在 $root\logs"
Write-Host "现在就启动：Start-ScheduledTask -TaskName $name"
