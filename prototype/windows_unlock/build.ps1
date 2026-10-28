param([string]$ZigPath)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'Only Windows x64 is supported.' }
$root = $PSScriptRoot
$out = Join-Path $root 'build'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$common = Join-Path $root 'native\common.cpp'
$provider = Join-Path $root 'native\provider.cpp'
$helper = Join-Path $root 'native\helper.cpp'
$tests = Join-Path $root 'native\tests.cpp'
# Nayuki QR Code generator v1.8.0 (MIT), vendored unmodified; only the helper's enrollment window uses it.
$qr = Join-Path $root 'native\qrcodegen.cpp'
$dll = Join-Path $out 'ProximityCredentialProvider.dll'
$exe = Join-Path $out 'ProximityUnlock.exe'
$testExe = Join-Path $out 'NativeTests.exe'
$libraries = @('advapi32', 'crypt32', 'bcrypt', 'wtsapi32', 'shell32', 'ole32', 'secur32', 'credui', 'user32', 'gdi32', 'uuid')
if (-not $ZigPath) {
    $zig = Get-Command zig -ErrorAction SilentlyContinue
    if ($zig) { $ZigPath = $zig.Source }
}
if ($ZigPath) {
    $flags = @('c++', '-target', 'x86_64-windows-gnu', '-std=c++17', '-O2', '-DUNICODE', '-D_UNICODE', '-Wall', '-Wextra')
    $links = $libraries | ForEach-Object { '-l' + $_ }
    & $ZigPath @flags '-shared' $provider $common @links '-o' $dll
    if ($LASTEXITCODE) { throw 'Credential Provider build failed.' }
    & $ZigPath @flags '-municode' $helper $common $qr @links '-o' $exe
    if ($LASTEXITCODE) { throw 'Native helper build failed.' }
    & $ZigPath @flags '-municode' $tests $common @links '-o' $testExe
    if ($LASTEXITCODE) { throw 'Native tests build failed.' }
} else {
    if (-not (Get-Command cl -ErrorAction SilentlyContinue)) { throw 'Use an x64 Visual Studio C++ developer shell with Windows SDK, or pass -ZigPath to a portable Zig 0.14.1 executable.' }
    Push-Location $out
    try {
        $flags = @('/nologo', '/std:c++17', '/EHsc', '/MT', '/O2', '/W4', '/DUNICODE', '/D_UNICODE', '/D_WIN32_WINNT=0x0A00', '/guard:cf')
        $links = $libraries | ForEach-Object { $_ + '.lib' }
        & cl @flags '/LD' $provider $common "/Fe:$dll" '/link' @links '/DYNAMICBASE' '/NXCOMPAT' '/HIGHENTROPYVA'
        if ($LASTEXITCODE) { throw 'Credential Provider build failed.' }
        & cl @flags $helper $common $qr "/Fe:$exe" '/link' @links '/DYNAMICBASE' '/NXCOMPAT' '/HIGHENTROPYVA'
        if ($LASTEXITCODE) { throw 'Native helper build failed.' }
        & cl @flags $tests $common "/Fe:$testExe" '/link' @links '/DYNAMICBASE' '/NXCOMPAT' '/HIGHENTROPYVA'
        if ($LASTEXITCODE) { throw 'Native tests build failed.' }
    } finally { Pop-Location }
}
& $testExe $dll
if ($LASTEXITCODE) { throw 'Native verification failed; do not install.' }
& $exe selftest
if ($LASTEXITCODE) { throw 'Native helper selftest failed; do not install.' }
Get-FileHash -LiteralPath $dll, $exe -Algorithm SHA256 | Format-Table -AutoSize
