# Copies supabase_anon_key.txt into assets/supabase_config.json so release APK
# picks up the key without --dart-define (still rebuild after running this).
#
# Usage: .\scripts\sync_supabase_config_from_keyfile.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$txt = Join-Path $root "supabase_anon_key.txt"
$out = Join-Path $root "assets\supabase_config.json"
if (-not (Test-Path $txt)) {
    Write-Error "Missing supabase_anon_key.txt at repo root."
}
$key = (Get-Content -Raw $txt).Trim()
if (-not $key) {
    Write-Error "supabase_anon_key.txt is empty."
}
$url = if ($env:SUPABASE_URL) { $env:SUPABASE_URL.Trim() } else { "https://prxmhmkndgvnlrbmnyxp.supabase.co" }

$obj = [ordered]@{ url = $url; anon_key = $key }
$json = ($obj | ConvertTo-Json -Compress)
[System.IO.File]::WriteAllText($out, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $out (do not commit real keys if your team treats this file as secret)."
