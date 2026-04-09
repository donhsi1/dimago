# Build debug APK (same dart-defines as build_android_release.ps1) and install on all
# connected Android devices via adb.
#
# Requires: Flutter, Android SDK platform-tools (adb), USB debugging or emulator.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$openai = $env:OPENAI_API_KEY
if (-not $openai) {
    $keyFile = Join-Path $root "openai_api_key.txt"
    if (Test-Path $keyFile) {
        $openai = (Get-Content -Raw $keyFile).Trim()
    }
}
if (-not $openai) { $openai = "" }

$sbAnon = $env:SUPABASE_ANON_KEY
if (-not $sbAnon) {
    $sbFile = Join-Path $root "supabase_anon_key.txt"
    if (Test-Path $sbFile) {
        $sbAnon = (Get-Content -Raw $sbFile).Trim()
    }
}
if (-not $sbAnon) { $sbAnon = "" }

$sbUrl = $env:SUPABASE_URL
if (-not $sbUrl) { $sbUrl = "https://prxmhmkndgvnlrbmnyxp.supabase.co" }

flutter build apk --debug `
    --dart-define=OPENAI_API_KEY="$openai" `
    --dart-define=SUPABASE_URL="$sbUrl" `
    --dart-define=SUPABASE_ANON_KEY="$sbAnon"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$apk = Join-Path $root "build\app\outputs\flutter-apk\app-debug.apk"
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

Write-Host "Android debug deploy finished."
