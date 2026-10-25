# ============================================================================
# pack_server_deploy.ps1 — build the Ubuntu server deployment bundle.
# ============================================================================
# Packages everything a remote Ubuntu host needs to run the Whiteboard
# server side in the direct-IP deployment model:
#
#   services/realtime/   Socket.IO collaboration service sources. Built on the
#                        server via `npm ci && npm run build` (Node 20 LTS).
#   web/                 Flutter Web build output (apps\web\build\web) with the
#                        realtime endpoint baked in at build time via
#                        --dart-define=WB_REALTIME_ENDPOINT=<endpoint>
#                        (the Web app connects to it directly; see
#                        apps/web/lib/services/realtime_service.dart).
#
#                        -Scheme https 时 endpoint 默认取 https://<addr>
#                        （443 同源：nginx 把 /socket.io/ 反代到本机 realtime
#                        端口）。投屏采集 getDisplayMedia/getUserMedia 只在
#                        安全上下文（HTTPS / localhost）可用，纯 HTTP + IP
#                        下 navigator.mediaDevices 为 undefined。
#   deploy/              install.sh + systemd/nginx templates + INFO.txt —
#                        the tarball is self-contained, the server-side
#                        installer reads the templates from here.
#
# Output:
#   <repo>\dist\whiteboard-server-deploy.tar.gz         (+ .sha256 sidecar)
#
# Usage:
#   tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress 203.0.113.10
#   tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress wb.example.com -RealtimePort 8790
#   tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress wb.example.com -Scheme https
#   tools\packaging\deploy\pack_server_deploy.ps1 -ServerAddress 203.0.113.10 -SkipWebBuild
#
# After packing (from the repository root):
#   scp .\dist\whiteboard-server-deploy.tar.gz <user>@<ServerAddress>:/tmp/
#   scp .\tools\packaging\deploy\install.sh    <user>@<ServerAddress>:/tmp/
#   ssh <user>@<ServerAddress> "sudo bash /tmp/install.sh /tmp/whiteboard-server-deploy.tar.gz"
#
# Notes:
#   * The Web endpoint is baked at build time. Re-run this script (without
#     -SkipWebBuild) whenever the server address changes.
#   * -SkipWebBuild reuses the existing apps\web\build\web output as-is; only
#     use it when that bundle already targets -ServerAddress.
#   * uses the Windows built-in tar (bsdtar), no extra tooling required.
#
# Exit codes: 0 = success, 1 = failure.
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Server IP or hostname the Web bundle will point at. Baked into the
    # Flutter Web build (WB_REALTIME_ENDPOINT) — no trailing slash.
    [Parameter(Mandatory = $true)]
    [string]$ServerAddress,

    # Realtime service port (default 8790, matches services/realtime DEFAULT_PORT).
    [int]$RealtimePort = 8790,

    # Web page scheme: http (default, direct IP + port) or https (domain + TLS).
    # https keeps the endpoint same-origin on 443 (nginx proxies /socket.io/
    # to the local realtime port). Screen/camera capture requires a secure
    # context, so HTTPS is mandatory for casting from a real server.
    [ValidateSet('http', 'https')]
    [string]$Scheme = 'http',

    # Full endpoint override (highest priority; e.g. a separate wss host).
    [string]$Endpoint,

    # Reuse the existing apps\web\build\web output instead of rebuilding.
    [switch]$SkipWebBuild,

    # Output directory for the tarball (default: <repo>\dist).
    [string]$OutDir,

    # Explicit flutter(.bat) path, forwarded to build_flutter.ps1.
    [string]$FlutterPath,

    # Optional --build-name override, forwarded to build_flutter.ps1 (web builds).
    [string]$BuildName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

$repoRoot    = Get-RepoRoot
$webBuildDir = Join-Path $repoRoot 'apps\web\build\web'
$realtimeSrc = Join-Path $repoRoot 'services\realtime'
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'dist' }

# NOTE: PowerShell variable names are case-insensitive, so the local variable
# must NOT be called $endpoint — that would overwrite the -Endpoint parameter
# (making a later `if ($Endpoint)` always true). Use $webEndpoint.
if ($Endpoint) {
    $webEndpoint = $Endpoint.Trim().TrimEnd('/')
    if ($webEndpoint -notmatch '^https?://') {
        throw "-Endpoint must start with http:// or https:// (got: $Endpoint)."
    }
} elseif ($Scheme -eq 'https') {
    # Same-origin on 443: the page and /socket.io/ share the TLS host, so the
    # browser has no mixed-content problem and realtime needs no public port.
    $webEndpoint = "https://$ServerAddress"
} else {
    $webEndpoint = "http://${ServerAddress}:${RealtimePort}"
}

Write-Host "[pack_server_deploy] Repository : $repoRoot"
Write-Host "[pack_server_deploy] Endpoint   : $webEndpoint"
Write-Host "[pack_server_deploy] Output dir : $OutDir"
if ($Scheme -eq 'https' -and -not $Endpoint) {
    Write-Host ("[pack_server_deploy] HTTPS mode : nginx 需把 /socket.io/ 反代到 127.0.0.1:{0}" -f $RealtimePort)
    Write-Host '[pack_server_deploy]              （install.sh --tls-domain 会写入对应模板）'
}

# --- 1. Build the Flutter Web bundle (endpoint baked in) ---------------------
if (-not $SkipWebBuild) {
    $flScript = Join-Path $repoRoot 'tools\scripts\build_flutter.ps1'
    if (-not (Test-Path -LiteralPath $flScript)) {
        throw "build_flutter.ps1 not found: $flScript"
    }
    # Hashtable splat (named binding). An *array* splat would not bind
    # -Target/-ExtraArgs here: build_flutter.ps1 declares
    # [CmdletBinding(PositionalBinding = $false)] with a
    # ValueFromRemainingArguments parameter, so bare tokens (e.g. '-Target')
    # would silently fall into $ExtraArgs and the target would stay 'windows'.
    # Same pattern as tools\scripts\build_all.ps1.
    $flArgs = @{
        Target    = 'web'
        ExtraArgs = @("--dart-define=WB_REALTIME_ENDPOINT=$webEndpoint")
    }
    if ($FlutterPath) { $flArgs['FlutterPath'] = $FlutterPath }
    if ($BuildName)   { $flArgs['BuildName'] = $BuildName }

    Write-Host "[pack_server_deploy] Building Flutter Web with WB_REALTIME_ENDPOINT=$webEndpoint ..."
    & $flScript @flArgs
    if ($LASTEXITCODE -ne 0) {
        throw "build_flutter.ps1 failed (exit $LASTEXITCODE)."
    }
} else {
    Write-Host '[pack_server_deploy] -SkipWebBuild: reusing apps\web\build\web as-is.'
}

# --- 2. Verify Web build output ---------------------------------------------
$required = @('index.html', 'flutter_bootstrap.js', 'main.dart.js', 'wb_core.js', 'wb_core.wasm')
foreach ($name in $required) {
    $p = Join-Path $webBuildDir $name
    if (-not (Test-Path -LiteralPath $p)) {
        throw ("Web build output is missing '$name' under $webBuildDir. " +
               'Run tools\scripts\build_flutter.ps1 -Target web ' +
               '(and tools\scripts\build_wasm.ps1 -CopyToWebAssets for the WASM core) first.')
    }
}

# --- 3. Stage the bundle -----------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$staging = Join-Path $env:TEMP "wb-server-deploy-$stamp"
$tarName = 'whiteboard-server-deploy.tar.gz'
$tarPath = Join-Path $OutDir $tarName

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    # 3a. services/realtime — runtime sources only (package.json/lock, tsconfig, src).
    $rtDst = Join-Path $staging 'services\realtime'
    New-Item -ItemType Directory -Path $rtDst -Force | Out-Null
    foreach ($file in @('package.json', 'package-lock.json', 'tsconfig.json')) {
        Copy-Item -LiteralPath (Join-Path $realtimeSrc $file) -Destination $rtDst
    }
    Copy-Item -LiteralPath (Join-Path $realtimeSrc 'src') -Destination (Join-Path $rtDst 'src') -Recurse

    # 3b. web/ — full Flutter Web output.
    Copy-Item -LiteralPath $webBuildDir -Destination (Join-Path $staging 'web') -Recurse

    # 3c. deploy/ — installer + templates (self-contained tarball).
    $depDst = Join-Path $staging 'deploy'
    New-Item -ItemType Directory -Path $depDst -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install.sh') -Destination $depDst
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'templates') -Destination (Join-Path $depDst 'templates') -Recurse

    $version = ''
    $versionFile = Join-Path $repoRoot 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }
    $infoLines = @(
        'whiteboard-server-deploy'
        "packed-at      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "server-address : $ServerAddress"
        "web-scheme     : $Scheme"
        "realtime-port  : $RealtimePort"
        "web-endpoint   : $webEndpoint"
        "version        : $version"
    )
    Set-Content -LiteralPath (Join-Path $depDst 'INFO.txt') -Value ($infoLines -join "`n") -Encoding ASCII

    # --- 4. Create the tarball ----------------------------------------------
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $tarPath) { Remove-Item -LiteralPath $tarPath -Force }

    Write-Host "[pack_server_deploy] Packing $tarName ..."
    tar -czf $tarPath -C $staging .
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed (exit $LASTEXITCODE)."
    }

    $hash = (Get-FileHash -LiteralPath $tarPath -Algorithm SHA256).Hash
    Set-Content -LiteralPath "$tarPath.sha256" -Value "$hash  $tarName" -Encoding ASCII
    $sizeMB = [Math]::Round(((Get-Item -LiteralPath $tarPath).Length / 1MB), 1)

    Write-Host ''
    Write-Host '====================================================================' -ForegroundColor Green
    Write-Host ' Deployment bundle ready' -ForegroundColor Green
    Write-Host "   Bundle : $tarPath ($sizeMB MB)"
    Write-Host "   SHA256 : $hash"
    Write-Host ''
    Write-Host ' Upload + deploy (run from the repository root):'
    Write-Host "   scp .\dist\$tarName <user>@${ServerAddress}:/tmp/"
    Write-Host "   scp .\tools\packaging\deploy\install.sh <user>@${ServerAddress}:/tmp/"
    $installArgs = "/tmp/$tarName"
    if ($Scheme -eq 'https' -and -not $Endpoint) {
        $installArgs += " --tls-domain $ServerAddress"
    }
    Write-Host "   ssh <user>@${ServerAddress} `"sudo bash /tmp/install.sh $installArgs`""
    Write-Host '====================================================================' -ForegroundColor Green
    exit 0
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
