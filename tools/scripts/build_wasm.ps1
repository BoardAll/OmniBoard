# ============================================================================
# build_wasm.ps1 — build the whiteboard C++ core for WebAssembly (Emscripten).
# ============================================================================
# Implements docs/构建打包与发布设计.md §6.6 (Web/WASM core build).
#
# Usage:
#   tools\scripts\build_wasm.ps1               # graceful skip when no EMSDK
#   tools\scripts\build_wasm.ps1 -Strict       # fail (exit 1) when no EMSDK
#   tools\scripts\build_wasm.ps1 -OutputDir build\wasm\dist
#   tools\scripts\build_wasm.ps1 -CopyToWebAssets   # opt-in: apps\web\web\
#
# Behaviour:
#   * If the EMSDK environment variable is missing (or points to a directory
#     without emcmake), the script prints installation instructions and exits
#     0 (skip) — or exits 1 with -Strict. This keeps build_all.ps1 usable on
#     machines without the (heavy) Emscripten SDK.
#   * With EMSDK present it runs the `wasm` CMAKE preset via
#     `emcmake cmake --preset wasm` + `cmake --build --preset wasm-release`,
#     then copies wb_core.js / wb_core.wasm / wb_core.worker.js (when present)
#     into -OutputDir (default: build\wasm\dist).
#
# Environment:
#   EMSDK      Path to the emsdk checkout (e.g. C:\emsdk), set by emsdk_env.
#   WB_CMAKE   Optional path to cmake.exe.
#
# Exit codes: 0 = built or skipped, 1 = failure (or skip with -Strict).
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Fail instead of skipping when EMSDK is unavailable (use in CI).
    [switch]$Strict,

    # Where the built js/wasm artifacts are collected.
    [string]$OutputDir,

    # Also copy the artifacts into apps\web\web\ (manual opt-in; the checked-in
    # wb_core.js / wb_core.wasm there are real artifacts updated in place).
    [switch]$CopyToWebAssets,

    # Explicit cmake.exe path (default: $env:WB_CMAKE, then PATH).
    [string]$CmakePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Write-EmsdkGuidance {
    Write-Host ''
    Write-Host '[build_wasm] EMSDK was not found — WASM core build skipped (graceful).' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'To enable the WASM core build:'
    Write-Host '  1) Install Emscripten (3.1.50+):'
    Write-Host '       git clone https://github.com/emscripten-core/emsdk.git C:\emsdk'
    Write-Host '       cd C:\emsdk'
    Write-Host '       .\emsdk.ps1 install latest'
    Write-Host '       .\emsdk.ps1 activate latest'
    Write-Host '  2) Load the environment in each new shell (sets EMSDK + PATH):'
    Write-Host '       C:\emsdk\emsdk_env.ps1'
    Write-Host '  3) Re-run: tools\scripts\build_wasm.ps1'
    Write-Host ''
    Write-Host 'The CMake `wasm` preset uses $env{EMSDK}\upstream\emscripten\cmake\Modules\Platform\Emscripten.cmake.'
    Write-Host 'See docs/构建打包与发布设计.md §3.2/§6.6 for details.'
}

try {
    $repoRoot = Get-RepoRoot
    if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'build\wasm\dist' }
    elseif (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
        $OutputDir = Join-Path $repoRoot $OutputDir
    }

    # --- 1) Detect the Emscripten SDK -----------------------------------------
    $emsdk = $env:EMSDK
    $emcmake = $null
    if ($emsdk -and (Test-Path -LiteralPath $emsdk)) {
        $candidate = Join-Path $emsdk 'upstream\emscripten\emcmake.bat'
        if (Test-Path -LiteralPath $candidate) { $emcmake = $candidate }
    }
    if (-not $emcmake) {
        # emcmake may also be on PATH when emsdk_env was loaded.
        $cmd = Get-Command emcmake -ErrorAction SilentlyContinue
        if ($cmd) { $emcmake = $cmd.Source }
    }

    if (-not $emcmake) {
        Write-EmsdkGuidance
        if ($Strict) { exit 1 } else { exit 0 }
    }

    Write-Host "[build_wasm] EMSDK   : $emsdk"
    Write-Host "[build_wasm] emcmake : $emcmake"

    # --- 2) Resolve cmake ------------------------------------------------------
    $cmake = $null
    if ($CmakePath) {
        if (-not (Test-Path -LiteralPath $CmakePath)) { throw "cmake not found: $CmakePath" }
        $cmake = (Resolve-Path -LiteralPath $CmakePath).Path
    } elseif ($env:WB_CMAKE -and (Test-Path -LiteralPath $env:WB_CMAKE)) {
        $cmake = (Resolve-Path -LiteralPath $env:WB_CMAKE).Path
    } else {
        $cmd = Get-Command cmake -ErrorAction SilentlyContinue
        if (-not $cmd) { throw 'cmake.exe not found. Set WB_CMAKE or add cmake to PATH.' }
        $cmake = $cmd.Source
    }

    Push-Location $repoRoot
    try {
        # --- 3) Configure via emcmake (wraps cmake with the Emscripten env) ----
        Write-Host '[build_wasm] [1/3] emcmake cmake --preset wasm ...'
        & $emcmake $cmake --preset wasm
        if ($LASTEXITCODE -ne 0) { throw "emcmake configure failed (exit $LASTEXITCODE)." }

        # --- 4) Build ----------------------------------------------------------
        Write-Host '[build_wasm] [2/3] cmake --build --preset wasm-release ...'
        & $cmake --build --preset wasm-release
        if ($LASTEXITCODE -ne 0) { throw "wasm build failed (exit $LASTEXITCODE)." }

        # --- 5) Collect artifacts ---------------------------------------------
        Write-Host '[build_wasm] [3/3] Collect artifacts...'
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        $wasmBuildDir = Join-Path $repoRoot 'build\wasm'
        $patterns = @('wb_core.js', 'wb_core.wasm', 'wb_core.worker.js')
        $found = @()
        foreach ($pattern in $patterns) {
            $file = Get-ChildItem -LiteralPath $wasmBuildDir -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            if ($file) {
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $OutputDir $file.Name) -Force
                $found += $file.Name
            }
        }
        if ($found.Count -eq 0) {
            Write-Host ("[build_wasm] WARNING: no wb_core.* artifacts found under $wasmBuildDir. " +
                        'Check WB_BUILD_WASM in the wasm preset / core CMake config.') -ForegroundColor Yellow
            exit 1
        }
        Write-Host ("[build_wasm] Collected: {0} -> {1}" -f ($found -join ', '), $OutputDir) -ForegroundColor Green

        if ($CopyToWebAssets) {
            $webAssets = Join-Path $repoRoot 'apps\web\web'
            if (Test-Path -LiteralPath $webAssets) {
                foreach ($name in $found) {
                    Copy-Item -LiteralPath (Join-Path $OutputDir $name) -Destination $webAssets -Force
                }
                Write-Host "[build_wasm] Copied to $webAssets (-CopyToWebAssets)."
            } else {
                Write-Host "[build_wasm] WARNING: $webAssets not found; skipping copy." -ForegroundColor Yellow
            }
        }
        exit 0
    } finally {
        Pop-Location
    }
} catch {
    Write-Host ("[build_wasm] ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
