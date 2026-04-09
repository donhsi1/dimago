# Build release APK (same dart-defines as build_android_release.ps1) and install on all
# connected Android devices via adb. Use this as the default "deploy" for Android.
#
# Requires: Flutter, Android SDK platform-tools (adb), USB debugging or emulator.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

& "$PSScriptRoot\build_android_release.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$apk = Join-Path $root "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $apk)) {
    Write-Error "APK missing: $apk"
    exit 1
}

try {
    $null = Get-Command adb -ErrorAction Stop
}
catch {
    Write-Error "adb not found. Add Android SDK platform-tools to PATH."
    exit 1
}

$serials = @()
foreach ($line in (adb devices 2>&1)) {
    if ($line -match '^(\S+)\s+device\s*$') {
        $serials += $Matches[1]
    }
}

if ($serials.Count -eq 0) {
    Write-Warning "No device in 'device' state. APK built: $apk"
    exit 0
}

foreach ($s in $serials) {
    Write-Host "adb install -r -> $s"
    adb -s $s install -r $apk
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "Android deploy finished."
