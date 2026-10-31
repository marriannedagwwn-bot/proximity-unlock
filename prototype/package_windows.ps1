# 打 Windows 安装包：ProximityUnlock-<版本>-Windows-x64.zip
#   先编译、验证原生组件：prototype\windows_unlock\build.ps1（会跑 NativeTests 和 helper 自检）
#   然后：powershell -ExecutionPolicy Bypass -File prototype\package_windows.ps1 -Version 0.1.1 [-OutDir <目录>]
# 只放运行要用的文件：电脑端脚本、依赖清单、安装说明、编好的 exe / dll。NativeTests.exe 也放：
# manage.ps1 -Action Install 装之前要在用户电脑上用它把 DLL 验一遍。不放 .pdb、测试、日志、.venv。
# 在中性路径里编译和打包（比如 C:\build\proximity-unlock），不然 exe 里可能带上用户目录。
param([Parameter(Mandatory)][string]$Version, [string]$OutDir)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root "dist" }
$name = "ProximityUnlock-$Version-Windows-x64"
$files = @(
    "LICENSE", "README.md", "INSTALL-Windows.md", "requirements-windows.txt",
    "prototype\win_peer.py", "prototype\win_unlock_protocol.py", "prototype\bt_toggle.py",
    "prototype\enroll_prompt.py", "prototype\install_autostart.ps1",
    "prototype\windows_unlock\__init__.py", "prototype\windows_unlock\backend.py",
    "prototype\windows_unlock\manage.ps1", "prototype\windows_unlock\README.md",
    "prototype\windows_unlock\THIRD_PARTY_NOTICES.txt",
    "prototype\windows_unlock\build\ProximityCredentialProvider.dll",
    "prototype\windows_unlock\build\ProximityUnlock.exe",
    "prototype\windows_unlock\build\NativeTests.exe"
)
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $f) -PathType Leaf)) { throw "缺文件：$f（原生组件先用 build.ps1 编译）" }
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$zip = Join-Path (Resolve-Path -LiteralPath $OutDir) "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
# 逐个写条目、路径用正斜杠：Windows PowerShell 5.1 的 Compress-Archive 可能写成反斜杠，别的解压工具认不出目录
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        $entry = "$name/" + $f.Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $root $f), $entry,
            [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $archive.Dispose() }
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
Write-Host "$hash  $name.zip"
Write-Host "已生成 $zip"
