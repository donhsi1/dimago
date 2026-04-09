# Release APK with API keys via --dart-define.
# For build + adb install on device(s), use deploy_android.ps1 in this folder.
#
# Talk transcription (OpenAI Whisper):
#   $env:OPENAI_API_KEY   or   openai_api_key.txt
#
# Supabase (optional; app skips init if anon key empty):
#   $env:SUPABASE_ANON_KEY   or   supabase_anon_key.txt
#   $env:SUPABASE_URL (optional; defaults to DimaGo project URL)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

$openai = $env:OPENAI_API_KEY
if (-not $openai) {
    $keyFile = Join-Path (Get-Location) "openai_api_key.txt"
    if (Test-Path $keyFile) {
        $openai = (Get-Content -Raw $keyFile).Trim()
    }
}
if (-not $openai) {
    $openai = ""
    Write-Host "(No OpenAI key — Talk mode will return empty transcripts until you add OPENAI_API_KEY or openai_api_key.txt)"
}

$sbAnon = $env:SUPABASE_ANON_KEY
if (-not $sbAnon) {
    $sbFile = Join-Path (Get-Location) "supabase_anon_key.txt"
    if (Test-Path $sbFile) {
        $sbAnon = (Get-Content -Raw $sbFile).Trim()
    }
}
if (-not $sbAnon) {
    $sbAnon = ""
    Write-Host "(No Supabase anon key — backend sync disabled until you add SUPABASE_ANON_KEY or supabase_anon_key.txt)"
}

$sbUrl = $env:SUPABASE_URL
if (-not $sbUrl) { $sbUrl = "https://prxmhmkndgvnlrbmnyxp.supabase.co" }

flutter build apk --release `
    --dart-define=OPENAI_API_KEY="$openai" `
    --dart-define=SUPABASE_URL="$sbUrl" `
    --dart-define=SUPABASE_ANON_KEY="$sbAnon"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "APK: build\app\outputs\flutter-apk\app-release.apk"
