# Build release APK with the same --dart-define secrets as flutter_run_with_secrets.ps1.
# Reads supabase_anon_key.txt (and optional OPENAI_API_KEY from openai_api_key.txt) when env unset.
#
# Usage:
#   .\scripts\flutter_build_apk_with_secrets.ps1
#   .\scripts\flutter_build_apk_with_secrets.ps1 appbundle

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

if (-not $sbAnon) {
    Write-Warning "SUPABASE_ANON_KEY is empty. Vocabulary download will fail unless assets/supabase_config.json contains anon_key."
}

$mode = if ($args.Count -gt 0) { $args[0] } else { "apk" }

$buildArgs = @(
    'build',
    $mode,
    '--release',
    "--dart-define=OPENAI_API_KEY=$openai",
    "--dart-define=SUPABASE_URL=$sbUrl",
    "--dart-define=SUPABASE_ANON_KEY=$sbAnon"
)
if ($args.Count -gt 1) {
    $buildArgs += $args[1..($args.Count - 1)]
}
& flutter @buildArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
