# flutter run with the same --dart-define secrets as flutter_build_apk_with_secrets.ps1
# (reads openai_api_key.txt / supabase_anon_key.txt when env unset).
#
# Usage:
#   .\scripts\flutter_run_with_secrets.ps1
#   .\scripts\flutter_run_with_secrets.ps1 -d <deviceId>
#   .\scripts\flutter_run_with_secrets.ps1 --release

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

$openai = $env:OPENAI_API_KEY
if (-not $openai) {
    $keyFile = Join-Path (Get-Location) "openai_api_key.txt"
    if (Test-Path $keyFile) {
        $openai = (Get-Content -Raw $keyFile).Trim()
    }
}
if (-not $openai) { $openai = "" }

$sbAnon = $env:SUPABASE_ANON_KEY
if (-not $sbAnon) {
    $sbFile = Join-Path (Get-Location) "supabase_anon_key.txt"
    if (Test-Path $sbFile) {
        $sbAnon = (Get-Content -Raw $sbFile).Trim()
    }
}
if (-not $sbAnon) { $sbAnon = "" }

$sbUrl = $env:SUPABASE_URL
if (-not $sbUrl) { $sbUrl = "https://prxmhmkndgvnlrbmnyxp.supabase.co" }

if (-not $openai) {
    Write-Warning "No OpenAI API key. Talk mode will not transcribe until you set OPENAI_API_KEY or openai_api_key.txt"
}

$runArgs = @(
    'run',
    "--dart-define=OPENAI_API_KEY=$openai",
    "--dart-define=SUPABASE_URL=$sbUrl",
    "--dart-define=SUPABASE_ANON_KEY=$sbAnon"
)
if ($args.Count -gt 0) {
    $runArgs += $args
}
& flutter @runArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
