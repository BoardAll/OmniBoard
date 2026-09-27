# Flutter SDK installer for Windows (mirror-friendly)
# Usage: powershell -ExecutionPolicy Bypass -File tools/scripts/setup_flutter_sdk.ps1
param(
  [string]$InstallDir = 'E:\code\flutter-sdk',
  [string]$MirrorBase = 'https://storage.flutter-io.cn/flutter_infra_release/releases'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$jsonPath = Join-Path $InstallDir 'releases_windows.json'

Write-Host "[1/4] Fetching release manifest..."
Invoke-WebRequest -Uri "$MirrorBase/releases_windows.json" -OutFile $jsonPath -UseBasicParsing

$json = Get-Content $jsonPath -Raw | ConvertFrom-Json
$hash = $json.current_release.stable
$rel = $json.releases | Where-Object { $_.hash -eq $hash } | Select-Object -First 1
if (-not $rel) { throw "Cannot resolve current stable release" }

$url = "$MirrorBase/$($rel.archive)"
$zip = Join-Path $InstallDir 'flutter.zip'
Write-Host "[2/4] Downloading Flutter $($rel.version): $url"
if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 100MB) {
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
} else {
  Write-Host "  zip already exists, skipping download"
}

Write-Host "[3/4] Extracting to $InstallDir ..."
Expand-Archive -Path $zip -DestinationPath $InstallDir -Force

Write-Host "[4/4] DONE: $InstallDir\flutter (version $($rel.version))"
Write-Host "Add to PATH: $InstallDir\flutter\bin"
