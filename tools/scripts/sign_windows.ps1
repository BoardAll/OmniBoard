# ============================================================================
# sign_windows.ps1 — Authenticode-sign Windows binaries with signtool.exe.
# ============================================================================
# Implements docs/构建打包与发布设计.md §9.1 (Windows code signing).
#
# Usage:
#   # Requires WB_SIGN_CERT (<path>.pfx) and WB_SIGN_PASSWORD:
#   $env:WB_SIGN_CERT     = 'C:\certs\whiteboard.pfx'
#   $env:WB_SIGN_PASSWORD = '******'
#   tools\scripts\sign_windows.ps1
#
#   # Sign an explicit file list:
#   tools\scripts\sign_windows.ps1 -Files dist\whiteboard-1.0.0-windows-x64.exe
#
#   # Certificate without a password (tests only):
#   tools\scripts\sign_windows.ps1 -CertHasNoPassword
#
# Behaviour when prerequisites are missing (no signtool / no certificate):
#   prints instructions and exits 0 ("skipped"), unless -Strict is given — then
#   it exits 1. This keeps local and CI pipelines usable without secrets.
#
# Default targets (when -Files is not given):
#   * every *.exe/*.msi/*.dll in <repo>\dist  (top level), and
#   * the built runner binaries:
#       apps\desktop\build\windows\x64\runner\Release\whiteboard_desktop.exe
#       apps\desktop\build\windows\x64\runner\Release\wb_core.dll
#   (whichever of these actually exist).
#
# Environment:
#   WB_SIGN_CERT       Path to the .pfx (or use -CertificatePath).
#   WB_SIGN_PASSWORD   Password for the .pfx (or use -CertificatePassword).
#   WB_SIGNTOOL        Optional explicit signtool.exe path.
#
# Exit codes: 0 = signed or skipped, 1 = failure (or skip with -Strict).
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Explicit files to sign (absolute or repo-relative paths).
    [string[]]$Files,

    # Directory scanned for *.exe/*.msi/*.dll when -Files is not given.
    [string]$Path = 'dist',

    # Path to the .pfx certificate (default: $env:WB_SIGN_CERT).
    [string]$CertificatePath,

    # Certificate password (default: $env:WB_SIGN_PASSWORD).
    [string]$CertificatePassword,

    # Set when the .pfx has no password; otherwise a missing password skips.
    [switch]$CertHasNoPassword,

    # RFC 3161 timestamp server.
    [string]$TimestampUrl = 'http://timestamp.digicert.com',

    # Skip timestamping (offline builds; not recommended for releases).
    [switch]$NoTimestamp,

    # Fail (exit 1) instead of skipping when prerequisites are missing.
    [switch]$Strict,

    # Explicit signtool.exe path (default: $env:WB_SIGNTOOL, then PATH, then
    # the newest Windows Kits 10 SDK installation).
    [string]$SigntoolPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Resolve-SigntoolExe {
    param([string]$Override)
    if ($Override) {
        if (Test-Path -LiteralPath $Override) { return (Resolve-Path -LiteralPath $Override).Path }
        throw "signtool not found at the path given via -SigntoolPath: $Override"
    }
    if ($env:WB_SIGNTOOL -and (Test-Path -LiteralPath $env:WB_SIGNTOOL)) {
        return (Resolve-Path -LiteralPath $env:WB_SIGNTOOL).Path
    }
    $cmd = Get-Command signtool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Probe the Windows SDK installation (signtool ships with the SDK, not on
    # PATH by default). x64 binaries only; x86 hosts are unsupported.
    $kitsBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $kitsBin) {
        $candidates = Get-ChildItem -LiteralPath $kitsBin -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^10\.' } |
            Sort-Object { [version]$_.Name } -Descending |
            ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
            Where-Object { Test-Path -LiteralPath $_ }
        $first = $candidates | Select-Object -First 1
        if ($first) { return $first }
    }
    return $null
}

try {
    $repoRoot = Get-RepoRoot
    $signtool = Resolve-SigntoolExe -Override $SigntoolPath
    if (-not $signtool) {
        Write-Host '[sign_windows] signtool.exe was not found (Windows SDK not installed?).' -ForegroundColor Yellow
        Write-Host '  Install the Windows 10/11 SDK (or Visual Studio "Desktop development with C++"),'
        Write-Host '  or point WB_SIGNTOOL at an existing signtool.exe.'
        if ($Strict) { exit 1 } else { exit 0 }
    }

    $cert = $CertificatePath
    if (-not $cert) { $cert = $env:WB_SIGN_CERT }
    if (-not $cert -or -not (Test-Path -LiteralPath $cert)) {
        Write-Host ('[sign_windows] No signing certificate configured — skipping. ' +
                    'Artifacts stay unsigned (development builds only).') -ForegroundColor Yellow
        Write-Host '  To enable signing (docs/构建打包与发布设计.md §9.1):'
        Write-Host '    $env:WB_SIGN_CERT     = "C:\certs\whiteboard.pfx"'
        Write-Host '    $env:WB_SIGN_PASSWORD = "<password>"'
        Write-Host '    tools\scripts\sign_windows.ps1'
        Write-Host '  Self-signed test certificate:'
        Write-Host '    New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=Whiteboard Test" `'
        Write-Host '      -CertStoreLocation Cert:\CurrentUser\My'
        if ($Strict) { exit 1 } else { exit 0 }
    }

    $password = $CertificatePassword
    if (-not $password) { $password = $env:WB_SIGN_PASSWORD }
    if (-not $password -and -not $CertHasNoPassword) {
        Write-Host ('[sign_windows] WB_SIGN_PASSWORD is not set — skipping to avoid an ' +
                    'interactive password prompt.') -ForegroundColor Yellow
        Write-Host '  Set WB_SIGN_PASSWORD, or pass -CertHasNoPassword for a passwordless .pfx.'
        if ($Strict) { exit 1 } else { exit 0 }
    }

    # --- Resolve the file list -------------------------------------------------
    $targets = @()
    if ($Files) {
        foreach ($f in $Files) {
            $resolved = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $repoRoot $f }
            if (Test-Path -LiteralPath $resolved) {
                $targets += (Resolve-Path -LiteralPath $resolved).Path
            } else {
                Write-Host ("[sign_windows] WARNING: file not found, skipped: " + $f) -ForegroundColor Yellow
            }
        }
    } else {
        $distDir = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }
        if (Test-Path -LiteralPath $distDir) {
            $targets += (Get-ChildItem -LiteralPath $distDir -File |
                Where-Object { $_.Extension -in @('.exe', '.msi', '.dll') } |
                Select-Object -ExpandProperty FullName)
        }
        $releaseDir = Join-Path $repoRoot 'apps\desktop\build\windows\x64\runner\Release'
        foreach ($name in @('whiteboard_desktop.exe', 'wb_core.dll')) {
            $candidate = Join-Path $releaseDir $name
            if (Test-Path -LiteralPath $candidate) { $targets += $candidate }
        }
    }

    $targets = @($targets | Select-Object -Unique)
    if ($targets.Count -eq 0) {
        if ($Strict) {
            Write-Host '[sign_windows] ERROR: nothing to sign but -Strict was requested.' -ForegroundColor Red
            exit 1
        }
        Write-Host '[sign_windows] Nothing to sign (no matching files found). Skipping.'
        exit 0
    }

    Write-Host "[sign_windows] signtool   : $signtool"
    Write-Host "[sign_windows] certificate: $cert"
    Write-Host ("[sign_windows] files      : " + $targets.Count)

    $failures = 0
    foreach ($target in $targets) {
        Write-Host ("[sign_windows] Signing " + $target)
        $signArgs = @('sign', '/fd', 'sha256', '/f', $cert)
        if ($password) { $signArgs += @('/p', $password) }
        if (-not $NoTimestamp) { $signArgs += @('/tr', $TimestampUrl, '/td', 'sha256') }
        $signArgs += $target
        & $signtool @signArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("[sign_windows] ERROR: signing failed for $target") -ForegroundColor Red
            $failures++
            continue
        }
        # Verify right after signing; a failed verification counts as a failure.
        & $signtool verify /pa $target
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("[sign_windows] ERROR: signature verification failed for $target") -ForegroundColor Red
            $failures++
        }
    }

    if ($failures -gt 0) {
        throw "$failures file(s) failed to sign."
    }
    Write-Host ("[sign_windows] OK: signed and verified {0} file(s)." -f $targets.Count) -ForegroundColor Green
    exit 0
} catch {
    Write-Host ("[sign_windows] ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
