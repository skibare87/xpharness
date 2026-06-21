# =====================================================================
#  Step 1 test: prove the XP-compatible curl can do TLS 1.2.
#  Run this BEFORE bothering with the harness. If it prints model JSON,
#  the hard part (TLS on XP) is solved.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File test-curl.ps1 YOUR_API_KEY
# =====================================================================
param([string]$ApiKey)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CurlExe = Join-Path $ScriptDir "bin\curl.exe"
$CaCert  = Join-Path $ScriptDir "bin\cacert.pem"

if (-not (Test-Path $CurlExe)) { Write-Host "missing bin\curl.exe" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $CaCert))  { Write-Host "missing bin\cacert.pem" -ForegroundColor Red; exit 1 }

Write-Host "curl version:" -ForegroundColor Green
& $CurlExe --version

Write-Host ""
Write-Host "TLS 1.2 reachability test (no auth needed):" -ForegroundColor Green
# howsmyssl reports back the negotiated TLS version
& $CurlExe -s -S --cacert $CaCert --tlsv1.2 "https://www.howsmyssl.com/a/check"
Write-Host ""

if ($ApiKey) {
    Write-Host ""
    Write-Host "Anthropic API test (lists models):" -ForegroundColor Green
    & $CurlExe -s -S --cacert $CaCert --tlsv1.2 `
        -H "x-api-key: $ApiKey" `
        -H "anthropic-version: 2023-06-01" `
        "https://api.anthropic.com/v1/models"
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "(pass your API key as an argument to also test the Anthropic endpoint)" -ForegroundColor DarkGray
}
