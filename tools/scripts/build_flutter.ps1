# ============================================================================
# build_flutter.ps1 — build the Flutter applications (desktop Windows / web).
# ============================================================================
# Implements docs/构建打包与发布设计.md §7 (Flutter app builds).
#
# Usage:
#   tools\scripts\build_flutter.ps1 -Target windows   # apps/desktop, Release
#   tools\scripts\build_flutter.ps1 -Target web       # apps/web, Release
#   tools\scripts\build_flutter.ps1 -Target web -Wasm # dart2wasm output
#   tools\scripts\build_flutter.ps1 -Target windows -NoSymlinkFallback
#
# Notes:
#   * Windows builds require the plugin symlinks that `flutter build` creates
#     under windows/flutter/ephemeral/.plugin_symlinks. Creating symlinks needs
#     Windows Developer Mode (or an elevated shell); when neither is available
#     this script pre-creates equivalent NTFS *junctions* (no privileges
#     needed). Disable with -NoSymlinkFallback.
#   * `--build-name/--build-number` are passed for web builds only: the
#     `flutter build windows` command does not accept them in the current SDK.
#   * The C++ core (wb_core.dll) is NOT built here. Run build_cpp.ps1 first (or
#     build_all.ps1): the Windows CMake install rule copies the DLL next to the
#     executable automatically when it exists.
#
# Environment:
#   WB_FLUTTER   Optional path to flutter(.bat). Default: flutter from PATH,
#                then <repo>\..\flutter-sdk\flutter\bin\flutter.bat.
#
# Exit codes: 0 = success, 1 = failure.
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Which app to build: 'windows' -> apps/desktop, 'web' -> apps/web.
    [ValidateSet('windows', 'web')]
    [string]$Target = 'windows',

    # Override the version embedded in web builds (default: repository VERSION).
    [string]$BuildName,

    # Override the build number embedded in web builds (default: '1').
    [string]$BuildNumber = '1',

    # Don't pass --build-name/--build-number (web target).
    [switch]$SkipVersionArgs,

    # Web only: build with dart2wasm (--wasm). Requires a wasm-compatible app.
    [switch]$Wasm,

    # Do not pre-create junction fallbacks for plugin symlinks.
    [switch]$NoSymlinkFallback,

    # Explicit flutter(.bat) path (default: $env:WB_FLUTTER, then PATH).
    [string]$FlutterPath,

    # Extra arguments forwarded verbatim to `flutter build <target>`.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Resolve-FlutterExe {
    param([string]$Override)
    if ($Override) {
        if (Test-Path -LiteralPath $Override) { return (Resolve-Path -LiteralPath $Override).Path }
        throw "flutter not found at the path given via -FlutterPath: $Override"
    }
    if ($env:WB_FLUTTER -and (Test-Path -LiteralPath $env:WB_FLUTTER)) {
        return (Resolve-Path -LiteralPath $env:WB_FLUTTER).Path
    }
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # SDK installed next to the monorepo by tools/scripts/setup_flutter_sdk.ps1.
    $sibling = Join-Path (Get-RepoRoot) '..\flutter-sdk\flutter\bin\flutter.bat'
    if (Test-Path -LiteralPath $sibling) { return (Resolve-Path -LiteralPath $sibling).Path }
    $userLocal = Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'
    if (Test-Path -LiteralPath $userLocal) { return (Resolve-Path -LiteralPath $userLocal).Path }
    throw "Flutter SDK not found. Set the WB_FLUTTER environment variable " +
          "(e.g. ..\flutter-sdk\flutter\bin\flutter.bat) or add flutter to PATH."
}

# ----------------------------------------------------------------------------
# Windows plugin symlink preflight.
#
# `flutter build windows` needs windows/flutter/ephemeral/.plugin_symlinks/<p>
# entries pointing at each Windows plugin package. Without Developer Mode (and
# without elevation) creating real symlinks fails with
#   "Building with plugins requires symlink support."
# and the build aborts *before* CMake runs.
#
# A junction (mklink /J) is an NTFS reparse point that does not require any
# privilege and is reported as a Link by the Dart VM, so the Flutter tool
# accepts an existing junction and skips creating a symlink for it.
# ----------------------------------------------------------------------------
function Test-SymlinkSupport {
    $probeRoot = Join-Path $env:TEMP ("wb_symlink_probe_" + [guid]::NewGuid().ToString('N'))
    $probeTarget = Join-Path $probeRoot 'probe_target'
    $probeLink = Join-Path $probeRoot 'probe_link'
    try {
        New-Item -ItemType Directory -Force -Path $probeTarget | Out-Null
        New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeTarget -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        # Best-effort cleanup of our own probe directory only.
        Remove-Item -LiteralPath $probeLink -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-WindowsPluginSymlinks {
    param([string]$AppDir, [switch]$Disabled)

    if ($Disabled) {
        Write-Host '[build_flutter] Plugin symlink preflight disabled (-NoSymlinkFallback).'
        return
    }

    $depFile = Join-Path $AppDir '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $depFile)) {
        Write-Host ("[build_flutter] NOTE: {0} not found (run 'flutter pub get' first); skipping plugin symlink preflight." -f
                    $depFile)
        return
    }

    if (Test-SymlinkSupport) {
        Write-Host '[build_flutter] Symlink support detected (Developer Mode / elevation OK).'
        return
    }

    Write-Host ('[build_flutter] WARNING: Symlink creation is unavailable ' +
                '(Developer Mode off and shell not elevated).') -ForegroundColor Yellow
    Write-Host ('[build_flutter] Falling back to NTFS junctions (mklink /J equivalent) ' +
                'for plugin directories.') -ForegroundColor Yellow

    $symlinkDir = Join-Path $AppDir 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Force -Path $symlinkDir | Out-Null

    $dep = Get-Content -LiteralPath $depFile -Raw | ConvertFrom-Json
    $plugins = @()
    if ($dep.plugins -and $dep.plugins.PSObject.Properties['windows']) {
        $plugins = @($dep.plugins.windows)
    }
    if ($plugins.Count -eq 0) {
        Write-Host '[build_flutter] No Windows plugins listed; nothing to do.'
        return
    }
    foreach ($plugin in $plugins) {
        $linkPath = Join-Path $symlinkDir ([string]$plugin.name)
        $linkTarget = ([string]$plugin.path).TrimEnd('\')
        if (Test-Path -LiteralPath $linkPath) {
            Write-Host ("  [skip] already present: " + $plugin.name)
            continue
        }
        New-Item -ItemType Junction -Path $linkPath -Target $linkTarget -ErrorAction Stop | Out-Null
        Write-Host ("  [junction] " + $plugin.name + ' -> ' + $linkTarget)
    }
    Write-Host ('[build_flutter] Junction fallback ready. (Tip: enable Developer Mode later ' +
                'to use real symlinks; junctions are re-created automatically if removed.)')
}

try {
    $repoRoot = Get-RepoRoot
    $flutter = Resolve-FlutterExe -Override $FlutterPath

    switch ($Target) {
        'windows' { $appDir = Join-Path $repoRoot 'apps\desktop' }
        'web'     { $appDir = Join-Path $repoRoot 'apps\web' }
    }
    if (-not (Test-Path -LiteralPath $appDir)) { throw "App directory not found: $appDir" }

    Write-Host "[build_flutter] Repository: $repoRoot"
    Write-Host "[build_flutter] flutter   : $flutter"
    Write-Host "[build_flutter] target    : $Target ($appDir)"

    if ($Target -eq 'windows') {
        Ensure-WindowsPluginSymlinks -AppDir $appDir -Disabled:$NoSymlinkFallback
    }

    # --- Assemble `flutter build <target>` arguments --------------------------
    $buildArgs = @('build', $Target, '--release')
    if ($Target -eq 'web' -and $Wasm) { $buildArgs += '--wasm' }

    if ($Target -eq 'web' -and -not $SkipVersionArgs) {
        $name = $BuildName
        if (-not $name) {
            $versionFile = Join-Path $repoRoot 'VERSION'
            if (Test-Path -LiteralPath $versionFile) {
                $name = (Get-Content -LiteralPath $versionFile -Raw).Trim()
            }
        }
        if ($name) {
            $buildArgs += "--build-name=$name"
            $buildArgs += "--build-number=$BuildNumber"
        } else {
            Write-Host '[build_flutter] VERSION file not found; skipping --build-name/--build-number.'
        }
    }
    if ($ExtraArgs) { $buildArgs += $ExtraArgs }

    Write-Host "[build_flutter] Running: flutter $($buildArgs -join ' ')"
    Push-Location $appDir
    try {
        & $flutter @buildArgs
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }

    # --- Verify artifacts -----------------------------------------------------
    if ($Target -eq 'windows') {
        $releaseDir = Join-Path $appDir 'build\windows\x64\runner\Release'
        $exe = Join-Path $releaseDir 'whiteboard_desktop.exe'
        $dll = Join-Path $releaseDir 'wb_core.dll'
        if (-not (Test-Path -LiteralPath $exe)) {
            throw "Build reported success but $exe is missing."
        }
        Write-Host ("[build_flutter] OK: " + $exe) -ForegroundColor Green
        if (Test-Path -LiteralPath $dll) {
            Write-Host ("[build_flutter] OK: " + $dll + ' (C++ core deployed next to the exe)') -ForegroundColor Green
        } else {
            Write-Host ("[build_flutter] WARNING: wb_core.dll is NOT next to the exe. " +
                        'Run tools\scripts\build_cpp.ps1 and rebuild to deploy it.') -ForegroundColor Yellow
        }
    } else {
        $index = Join-Path $appDir 'build\web\index.html'
        if (-not (Test-Path -LiteralPath $index)) {
            throw "Build reported success but $index is missing."
        }
        $webFiles = (Get-ChildItem (Join-Path $appDir 'build\web') -Recurse -File |
                     Measure-Object -Property Length -Sum)
        Write-Host ("[build_flutter] OK: {0} ({1} files, {2:N1} MB)" -f
                    $index, $webFiles.Count, ($webFiles.Sum / 1MB)) -ForegroundColor Green
    }
    exit 0
} catch {
    Write-Host ("[build_flutter] ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
