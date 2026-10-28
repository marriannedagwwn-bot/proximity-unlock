param(
    [ValidateSet('Install','Uninstall','Enroll','EnrollEmpty','RemoveEnrollment','Export','Status')]
    [string]$Action = 'Status',
    [switch]$Enroll,
    [switch]$EnrollEmpty
)
$ErrorActionPreference = 'Stop'
if ($Enroll -and $EnrollEmpty) { throw 'Choose either normal or explicit passwordless enrollment.' }
$clsid = '{908BDBA7-6A55-4C85-B4AB-33B7D99A76C0}'
$install = Join-Path $env:ProgramFiles 'ProximityUnlock'
$helper = Join-Path $install 'ProximityUnlock.exe'
$providerReg = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$clsid"
$comReg = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
$resultPath = Join-Path $install 'setup-result.txt'
$setupNotes = @()
$setupStage = 'Initialize'
$needsAdmin = $Action -in @('Install','Uninstall','Enroll','EnrollEmpty','RemoveEnrollment')
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($needsAdmin -and -not $admin) {
    # The human must accept UAC; this code never interacts with the approval UI.
    $shell = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Action', $Action)
    if ($Enroll) { $arguments += '-Enroll' }
    if ($EnrollEmpty) { $arguments += '-EnrollEmpty' }
    $started = [DateTime]::UtcNow
    $process = Start-Process -FilePath $shell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ((Test-Path -LiteralPath $resultPath) -and (Get-Item -LiteralPath $resultPath).LastWriteTimeUtc -ge $started) {
        Get-Content -LiteralPath $resultPath
    }
    if ($process.ExitCode) { throw "Elevated operation failed ($($process.ExitCode))." }
    if ($Action -ne 'Uninstall' -and (Test-Path -LiteralPath $helper)) { & $helper status }
    exit 0
}
if (-not [Environment]::Is64BitProcess) { throw 'Run the 64-bit PowerShell host.' }
function Move-SetupFileAtomically([string]$Source, [string]$Target) {
    $directory = [IO.Path]::GetFullPath($install).TrimEnd('\')
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $targetPath = [IO.Path]::GetFullPath($Target)
    foreach ($path in @($sourcePath, $targetPath)) {
        if (-not [String]::Equals([IO.Path]::GetDirectoryName($path), $directory, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Atomic replacement paths must stay directly inside the fixed install directory.'
        }
    }
    $targetName = [IO.Path]::GetFileName($targetPath)
    if ($targetName -notin @('ProximityCredentialProvider.dll', 'ProximityUnlock.exe', 'setup-result.txt')) {
        throw 'Atomic replacement target is not an allowed setup file.'
    }
    if ([IO.Path]::GetFileName($sourcePath) -notmatch '^[a-f0-9]{32}\.tmp$') {
        throw 'Atomic replacement source must be a fresh setup temporary file.'
    }
    foreach ($path in @($sourcePath, $targetPath)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Atomic replacement paths may not be directories or reparse points.'
            }
        }
    }
    if (-not ('ProximityUnlockSetup.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace ProximityUnlockSetup {
    public static class NativeMethods {
        [DllImport("kernel32.dll", EntryPoint="MoveFileExW", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool MoveFileEx(string source, string target, uint flags);
    }
}
'@
    }
    # Win32 replaces the directory entry atomically, including an existing target.
    # It does not write through the old target file (which could be a hardlink).
    if ([ProximityUnlockSetup.NativeMethods]::MoveFileEx($sourcePath, $targetPath, 9)) { return }
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($targetName -eq 'setup-result.txt' -or -not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        throw [ComponentModel.Win32Exception]::new($code, "Atomic replacement of $targetName failed (Win32 $code).")
    }
    # Windows permits a loaded image to be renamed but may reject replacement
    # over it (ERROR_ACCESS_DENIED). Keep its mapped image under a unique name,
    # then install the new file at the registered path. No process is stopped.
    $backup = [IO.Path]::GetFullPath((Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.backup')))
    if (-not [String]::Equals([IO.Path]::GetDirectoryName($backup), $directory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Component backup must stay inside the fixed install directory.'
    }
    if (-not [ProximityUnlockSetup.NativeMethods]::MoveFileEx($targetPath, $backup, 8)) {
        $renameCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw [ComponentModel.Win32Exception]::new($renameCode, "Replacement of $targetName failed (Win32 $code); renaming its old image also failed (Win32 $renameCode).")
    }
    if (-not [ProximityUnlockSetup.NativeMethods]::MoveFileEx($sourcePath, $targetPath, 9)) {
        $replaceCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $restored = [ProximityUnlockSetup.NativeMethods]::MoveFileEx($backup, $targetPath, 9)
        $restoreCode = if ($restored) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
        throw [ComponentModel.Win32Exception]::new($replaceCode, "Installing new $targetName failed (Win32 $replaceCode); rollback success=$restored (Win32 $restoreCode), backup=$backup.")
    }
    try { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
    catch {
        $note = "Previous mapped $targetName retained at $backup; it can be deleted after Windows releases the image."
        $script:setupNotes += $note
        Write-Output $note
    }
}
function Write-SetupResult([string]$Result, [string]$Message) {
    if (-not $admin -or -not (Test-Path -LiteralPath $install)) { return }
    $item = Get-Item -LiteralPath $install -Force
    $owner = (Get-Acl -LiteralPath $install).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $owner -notin @('S-1-5-18','S-1-5-32-544')) { return }
    $temporary = Join-Path $install ([Guid]::NewGuid().ToString('N') + '.tmp')
    # Explicit status only. Never transcript the password dialog or key window.
    @("UTC: $([DateTime]::UtcNow.ToString('o'))", "Action: $Action", "Stage: $setupStage", "Result: $Result", $Message) + @($setupNotes) |
        Set-Content -LiteralPath $temporary -Encoding UTF8
    try { Move-SetupFileAtomically $temporary $resultPath }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Remove-OurRegistryTree64([string]$RelativePath) {
    $allowed = @(
        "SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$clsid",
        "SOFTWARE\Classes\CLSID\$clsid",
        'SOFTWARE\ProximityUnlock'
    )
    if ($RelativePath -notin $allowed) { throw 'Registry cleanup is restricted to this component''s three fixed keys.' }
    if (-not ('ProximityUnlockSetup.RegistryMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ProximityUnlockSetup {
    public static class RegistryMethods {
        [DllImport("advapi32.dll", EntryPoint="RegDeleteTreeW", CharSet=CharSet.Unicode)]
        public static extern int DeleteTree(IntPtr hive, string subkey);
    }
}
'@
    }
    # Do not request write access to the entire SOFTWARE/CLSID parent. The
    # native call opens only our allowlisted subtree. This is a 64-bit host.
    $hklm = [IntPtr]::new(-2147483646)
    $code = [ProximityUnlockSetup.RegistryMethods]::DeleteTree($hklm, $RelativePath)
    if ($code -notin @(0, 2, 3)) {
        throw [ComponentModel.Win32Exception]::new($code, "Cannot remove component registry key $RelativePath (Win32 $code).")
    }
}
try {
switch ($Action) {
    'Install' {
        $setupStage = 'Install.ValidateBuild'
        $build = Join-Path $PSScriptRoot 'build'
        $dllSource = Join-Path $build 'ProximityCredentialProvider.dll'
        $helperSource = Join-Path $build 'ProximityUnlock.exe'
        $tests = Join-Path $build 'NativeTests.exe'
        if (-not (Test-Path -LiteralPath $tests)) { throw 'Build and verify the native components first.' }
        & $tests $dllSource
        if ($LASTEXITCODE) { throw 'Native tests failed.' }
        $setupStage = 'Install.SecureDirectory'
        if (Test-Path -LiteralPath $install) {
            $item = Get-Item -LiteralPath $install -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Install directory may not be a reparse point.' }
            $owner = (Get-Acl -LiteralPath $install).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($owner -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Install directory owner is not SYSTEM/Administrators.' }
        } else { New-Item -ItemType Directory -Path $install | Out-Null }
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorSddlForm('O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)')
        Set-Acl -LiteralPath $install -AclObject $acl
        # Disable our own provider during replacement. All system providers are kept.
        $setupStage = 'Install.DisableOwnProvider'
        if (Test-Path -LiteralPath $providerReg) { New-ItemProperty -LiteralPath $providerReg -Name Disabled -Value 1 -PropertyType DWord -Force | Out-Null }
        foreach ($source in @($dllSource, $helperSource)) {
            $setupStage = 'Install.Replace.' + [IO.Path]::GetFileName($source)
            $target = Join-Path $install ([IO.Path]::GetFileName($source))
            $temporary = Join-Path $install ([Guid]::NewGuid().ToString('N') + '.tmp')
            # A fresh file inherits the secured directory ACL. Replacing a directory
            # entry avoids writing through a pre-existing file hardlink/reparse point.
            Copy-Item -LiteralPath $source -Destination $temporary
            try { Move-SetupFileAtomically $temporary $target }
            finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
        }
        $setupStage = 'Install.RegisterCOM'
        New-Item -Path "$comReg\InprocServer32" -Force | Out-Null
        Set-Item -LiteralPath "$comReg\InprocServer32" -Value (Join-Path $install 'ProximityCredentialProvider.dll')
        New-ItemProperty -LiteralPath "$comReg\InprocServer32" -Name ThreadingModel -Value Apartment -PropertyType String -Force | Out-Null
        $setupStage = 'Install.RegisterOwnProvider'
        New-Item -Path $providerReg -Force | Out-Null
        Set-Item -LiteralPath $providerReg -Value 'iPhone Proximity Unlock'
        New-ItemProperty -LiteralPath $providerReg -Name Disabled -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Output 'Installed only our Credential Provider. System password/PIN providers remain available.'
        $setupStage = 'Install.Enrollment'
        if ($Enroll) { & $helper enroll; if ($LASTEXITCODE) { throw 'Enrollment was cancelled or failed; provider stays inactive without valid enrollment.' } }
        if ($EnrollEmpty) { & $helper enroll-empty; if ($LASTEXITCODE) { throw "Passwordless enrollment cancelled or failed (Win32/exit $LASTEXITCODE). Account password and security policies were not changed." } }
        $setupStage = 'Install.CheckStatus'
        & $helper status
    }
    'Enroll' { $setupStage='Enroll.Helper'; & $helper enroll; if ($LASTEXITCODE) { throw "Enrollment cancelled or failed (Win32/exit $LASTEXITCODE)." } }
    'EnrollEmpty' { $setupStage='EnrollEmpty.Helper'; & $helper enroll-empty; if ($LASTEXITCODE) { throw "Passwordless enrollment cancelled or failed (Win32/exit $LASTEXITCODE). Account password and security policies were not changed." } }
    'RemoveEnrollment' { $setupStage='RemoveEnrollment.Helper'; & $helper remove; if ($LASTEXITCODE) { throw 'Enrollment removal failed.' } }
    'Export' { $setupStage='Export.Helper'; & $helper export; if ($LASTEXITCODE) { throw 'Export cancelled or failed.' } }
    'Status' { if (Test-Path -LiteralPath $helper) { & $helper status } else { Write-Output '{"available":false,"installed":false}' } }
    'Uninstall' {
        # Unregister first: file cleanup can be repeated safely after LogonUI exits.
        $setupStage = 'Uninstall.RemoveOwnProviderRegistration'
        Remove-OurRegistryTree64 "SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$clsid"
        $setupStage = 'Uninstall.RemoveOwnCOMRegistration'
        Remove-OurRegistryTree64 "SOFTWARE\Classes\CLSID\$clsid"
        $setupStage = 'Uninstall.RemoveEnrollmentViaHelper'
        if (Test-Path -LiteralPath $helper) { & $helper remove; if ($LASTEXITCODE) { Write-Warning 'Enrollment cleanup failed; rerun as the unlocked enrolled local console account.' } }
        $setupStage = 'Uninstall.RemoveEncryptedEnrollmentFile'
        $data = Join-Path $env:ProgramData 'ProximityUnlock'
        if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath (Join-Path $data 'enrollment.bin') -Force -ErrorAction SilentlyContinue }
        $setupStage = 'Uninstall.RemoveOwnConfigurationRegistry'
        Remove-OurRegistryTree64 'SOFTWARE\ProximityUnlock'
        foreach ($file in @('ProximityCredentialProvider.dll','ProximityUnlock.exe')) {
            $setupStage = 'Uninstall.Remove.' + $file
            $target = Join-Path $install $file
            if (Test-Path -LiteralPath $target) { try { Remove-Item -LiteralPath $target -Force } catch { Write-Warning "Close the current LogonUI session or restart, then remove $target" } }
        }
        Write-Output 'Our Credential Provider was unregistered. System providers were preserved.'
    }
}
if ($needsAdmin) { Write-SetupResult 'Completed' 'Requested component operation completed; use helper status for enrollment availability.' }
} catch {
    $failure = $_
    $details = @(
        $failure.Exception.Message,
        "ExceptionType: $($failure.Exception.GetType().FullName)",
        "HResult: $($failure.Exception.HResult)",
        "FullyQualifiedErrorId: $($failure.FullyQualifiedErrorId)",
        "ScriptStackTrace: $($failure.ScriptStackTrace)",
        "Position: $($failure.InvocationInfo.PositionMessage)"
    ) -join [Environment]::NewLine
    Write-SetupResult 'Failed' $details
    Write-Error $failure
    exit 1
}
exit 0
