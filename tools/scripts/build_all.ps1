# ============================================================================
# build_all.ps1 — one-command build orchestrator (Windows-first).
# ============================================================================
# Implements docs/构建打包与发布设计.md §8.1 (one-shot build) for the
# Windows host, wired to the individual scripts in tools/scripts:
#
#   1) C++ core        -> build_cpp.ps1     (cmake preset windows-x64)
#   2) Windows app     -> build_flutter.ps1 -Target windows
#                         (the CMake install rule deploys wb_core.dll next to
#                          whiteboard_desktop.exe automatically)
#   3) Web app         -> build_flutter.ps1 -Target web
#   4) WASM core       -> build_wasm.ps1    (graceful skip without EMSDK)
#   5) Checksums       -> checksum.ps1      (only when dist\ exists)
#
# Usage:
#   tools\scripts\build_all.ps1
#   tools\scripts\build_all.ps1 -SkipCpp -SkipWasm          # windows + web only
#   tools\scripts\build_all.ps1 -RunCppTests                # also ctest
#   tools\scripts\build_all.ps1 -SkipWindows -SkipWeb       # core only
#
# Every step fails fast: the first failing step aborts the run with a clear
# message and a non-zero exit code. Nothing is deleted; all build outputs stay
# under build\ directories (plus dist\ artifacts when they exist).
#
# Exit codes: 0 = all requested steps succeeded, 1 = a step failed.
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Skip the C++ core build (step 1).
    [switch]$SkipCpp,

    # Skip the Windows desktop app build (step 2).
    [switch]$SkipWindows,

    # Skip the Web app build (step 3).
    [switch]$SkipWeb,

    # Skip the WASM core build (step 4; it is a graceful no-op without EMSDK).
    [switch]$SkipWasm,

    # Skip the checksum step (step 5).
    [switch]$SkipChecksum,

    # Pass -RunTests through to build_cpp.ps1 (ctest after the C++ build).
    [switch]$RunCppTests,

    # Build the web app with dart2wasm (passes --wasm to flutter build web).
    [switch]$WebWasm,

    # Disable the junction fallback used when symlinks are unavailable.
    [switch]$NoSymlinkFallback,

    # Explicit flutter(.bat) / cmake.exe paths (env: WB_FLUTTER / WB_CMAKE).
    [string]$FlutterPath,
    [string]$CmakePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Invoke-BuildStep {
    param(
        [string]$StepName,
        [scriptblock]$Body
    )
    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host ("  $StepName")
    Write-Host ('=' * 72)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Body
    $exitCode = $LASTEXITCODE
    $sw.Stop()
    if ($exitCode -ne 0) {
        throw ("Step '$StepName' failed with exit code $exitCode " +
               "(after $([math]::Round($sw.Elapsed.TotalSeconds, 1))s). Aborting build_all.")
    }
    Write-Host ("[build_all] $StepName OK ({0:N1}s)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
}

try {
    $repoRoot = Get-RepoRoot
    $scriptsDir = $PSScriptRoot
    $results = [ordered]@{}

    Write-Host "[build_all] Repository : $repoRoot"
    Write-Host "[build_all] Scripts    : $scriptsDir"
    $plan = @()
    if (-not $SkipCpp) { $plan += 'cpp' }
    if (-not $SkipWindows) { $plan += 'windows-app' }
    if (-not $SkipWeb) { $plan += 'web-app' }
    if (-not $SkipWasm) { $plan += 'wasm-core' }
    if (-not $SkipChecksum) { $plan += 'checksums' }
    Write-Host ("[build_all] Steps      : " + ($plan -join ' -> '))

    # --- 1) C++ core -----------------------------------------------------------
    if (-not $SkipCpp) {
        # NOTE: hashtable splatting is mandatory for script-to-script calls.
        # Array splatting passes elements POSITIONALLY, so @('-RunTests')
        # would bind to the first positional parameter instead of the
        # -RunTests switch (observed: build_cpp.ps1 got $Preset='-RunTests').
        $cppArgs = @{}
        if ($RunCppTests) { $cppArgs['RunTests'] = $true }
        if ($CmakePath) { $cppArgs['CmakePath'] = $CmakePath }
        Invoke-BuildStep -StepName '1/5 C++ core (cmake preset windows-x64)' -Body {
            & (Join-Path $scriptsDir 'build_cpp.ps1') @cppArgs
        }
        $results['cpp'] = 'ok'
    } else {
        Write-Host '[build_all] 1/5 C++ core skipped (-SkipCpp).'
        $results['cpp'] = 'skipped'
    }

    # --- 2) Windows app ---------------------------------------------------------
    if (-not $SkipWindows) {
        $winArgs = @{ Target = 'windows' }
        if ($NoSymlinkFallback) { $winArgs['NoSymlinkFallback'] = $true }
        if ($FlutterPath) { $winArgs['FlutterPath'] = $FlutterPath }
        Invoke-BuildStep -StepName '2/5 Windows app (flutter build windows --release)' -Body {
            & (Join-Path $scriptsDir 'build_flutter.ps1') @winArgs
        }
        $results['windows'] = 'ok'

        # Deploy verification: exe + wb_core.dll together in the Release dir.
        $releaseDir = Join-Path $repoRoot 'apps\desktop\build\windows\x64\runner\Release'
        $exe = Join-Path $releaseDir 'whiteboard_desktop.exe'
        $dll = Join-Path $releaseDir 'wb_core.dll'
        if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $dll)) {
            Write-Host "[build_all] Deploy check OK: exe + wb_core.dll in $releaseDir" -ForegroundColor Green
        } else {
            Write-Host ("[build_all] WARNING: deploy check — exe={0}, wb_core.dll={1} in {2}." -f
                        (Test-Path -LiteralPath $exe), (Test-Path -LiteralPath $dll), $releaseDir) -ForegroundColor Yellow
            Write-Host '  Run build_cpp.ps1 (without -SkipCpp) and rebuild the app.' -ForegroundColor Yellow
        }
    } else {
        Write-Host '[build_all] 2/5 Windows app skipped (-SkipWindows).'
        $results['windows'] = 'skipped'
    }

    # --- 3) Web app -------------------------------------------------------------
    if (-not $SkipWeb) {
        $webArgs = @{ Target = 'web' }
        if ($WebWasm) { $webArgs['Wasm'] = $true }
        if ($FlutterPath) { $webArgs['FlutterPath'] = $FlutterPath }
        Invoke-BuildStep -StepName '3/5 Web app (flutter build web --release)' -Body {
            & (Join-Path $scriptsDir 'build_flutter.ps1') @webArgs
        }
        $results['web'] = 'ok'
    } else {
        Write-Host '[build_all] 3/5 Web app skipped (-SkipWeb).'
        $results['web'] = 'skipped'
    }

    # --- 4) WASM core (graceful skip without EMSDK) ------------------------------
    if (-not $SkipWasm) {
        Invoke-BuildStep -StepName '4/5 WASM core (Emscripten; skips gracefully)' -Body {
            & (Join-Path $scriptsDir 'build_wasm.ps1')
        }
        $results['wasm'] = 'ok-or-skipped'
    } else {
        Write-Host '[build_all] 4/5 WASM core skipped (-SkipWasm).'
        $results['wasm'] = 'skipped'
    }

    # --- 5) Checksums (only when there is a dist\ directory) ---------------------
    if (-not $SkipChecksum) {
        $distDir = Join-Path $repoRoot 'dist'
        if (Test-Path -LiteralPath $distDir) {
            Invoke-BuildStep -StepName '5/5 Checksums (dist\SHA256SUMS)' -Body {
                & (Join-Path $scriptsDir 'checksum.ps1') -Path $distDir
            }
            $results['checksums'] = 'ok'
        } else {
            Write-Host '[build_all] 5/5 Checksums skipped: no dist\ directory (installers are not built yet).'
            $results['checksums'] = 'skipped'
        }
    } else {
        Write-Host '[build_all] 5/5 Checksums skipped (-SkipChecksum).'
        $results['checksums'] = 'skipped'
    }

    # --- Summary -----------------------------------------------------------------
    Write-Host ''
    Write-Host '[build_all] Summary:'
    foreach ($key in $results.Keys) {
        Write-Host ("  {0,-12} {1}" -f $key, $results[$key])
    }
    Write-Host ''
    Write-Host '[build_all] DONE.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host ''
    Write-Host ("[build_all] ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
