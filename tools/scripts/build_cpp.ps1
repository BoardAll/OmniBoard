# ============================================================================
# build_cpp.ps1 — build the whiteboard C++ core engine (wb_core) with CMake.
# ============================================================================
# Implements docs/构建打包与发布设计.md §6 (C++ core build) for Windows.
#
# Usage:
#   tools\scripts\build_cpp.ps1                     # configure + build (Release)
#   tools\scripts\build_cpp.ps1 -RunTests           # ... and run ctest
#   tools\scripts\build_cpp.ps1 -Config Debug       # Debug configuration
#   tools\scripts\build_cpp.ps1 -Preset windows-x64 -Fresh
#
# Environment:
#   WB_CMAKE   Optional path to cmake.exe. Resolution order: the -CmakePath
#              parameter, then $env:WB_CMAKE, then cmake.exe on PATH (ctest is
#              resolved next to the cmake executable). No machine-specific
#              directories are hard-coded.
#
# Output (default preset):
#   build\windows-x64\bin\Release\wb_core.dll   (VS multi-config layout)
#
# Exit codes: 0 = success, 1 = failure.
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Configure preset from CMakePresets.json (e.g. windows-x64).
    [string]$Preset = 'windows-x64',

    # Build/test configuration.
    [ValidateSet('Release', 'Debug')]
    [string]$Config = 'Release',

    # Also run ctest after the build (test preset / test-dir fallback).
    [switch]$RunTests,

    # Pass --fresh to the configure step (wipes the CMake cache; CMake >= 3.24).
    [switch]$Fresh,

    # Explicit cmake.exe path (default: $env:WB_CMAKE, then PATH).
    [string]$CmakePath,

    # Monorepo root containing CMakePresets.json (default: repository root).
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Resolve-CmakeExe {
    param([string]$Override)
    if ($Override) {
        if (Test-Path -LiteralPath $Override) { return (Resolve-Path -LiteralPath $Override).Path }
        throw "cmake not found at the path given via -CmakePath: $Override"
    }
    if ($env:WB_CMAKE -and (Test-Path -LiteralPath $env:WB_CMAKE)) {
        return (Resolve-Path -LiteralPath $env:WB_CMAKE).Path
    }
    $cmd = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "cmake.exe not found. Install CMake 3.20+ (Visual Studio 2022 generator) " +
          "and either add it to PATH or set the WB_CMAKE environment variable."
}

# ctest ships next to cmake.exe in the standard CMake installation; prefer that
# copy so -CmakePath / WB_CMAKE setups work even when CMake is not on PATH.
function Resolve-CtestExe {
    param([string]$CmakeExePath)
    $candidate = Join-Path (Split-Path -Parent $CmakeExePath) 'ctest.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $cmd = Get-Command ctest -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-PresetKindNames {
    param([string]$PresetsJsonPath, [string]$Kind)
    $json = Get-Content -LiteralPath $PresetsJsonPath -Raw | ConvertFrom-Json
    $list = @()
    if ($json.PSObject.Properties[$Kind]) { $list = @($json.$Kind) }
    return @($list | ForEach-Object { $_.name })
}

try {
    $repoRoot = if ($SourceDir) { (Resolve-Path -LiteralPath $SourceDir).Path } else { Get-RepoRoot }
    $presetsJson = Join-Path $repoRoot 'CMakePresets.json'
    if (-not (Test-Path -LiteralPath $presetsJson)) {
        throw "CMakePresets.json not found under '$repoRoot'."
    }
    $cmake = Resolve-CmakeExe -Override $CmakePath

    $configurePresets = Get-PresetKindNames -PresetsJsonPath $presetsJson -Kind 'configurePresets'
    if ($configurePresets -notcontains $Preset) {
        throw ("Configure preset '{0}' is not defined in CMakePresets.json. Available: {1}" -f
               $Preset, ($configurePresets -join ', '))
    }

    Write-Host "[build_cpp] Repository : $repoRoot"
    Write-Host "[build_cpp] cmake      : $cmake"
    Write-Host "[build_cpp] preset     : $Preset ($Config)"

    Push-Location $repoRoot
    try {
        # --- 1) Configure -----------------------------------------------------
        Write-Host '[build_cpp] [1/3] Configure...'
        $configureArgs = @('--preset', $Preset)
        if ($Fresh) { $configureArgs += '--fresh' }
        & $cmake @configureArgs
        if ($LASTEXITCODE -ne 0) { throw "cmake configure failed (exit $LASTEXITCODE)." }

        # --- 2) Build ---------------------------------------------------------
        Write-Host '[build_cpp] [2/3] Build...'
        $buildPresets = Get-PresetKindNames -PresetsJsonPath $presetsJson -Kind 'buildPresets'
        $buildPresetName = "{0}-{1}" -f $Preset, $Config.ToLowerInvariant()
        if ($buildPresets -contains $buildPresetName) {
            & $cmake --build --preset $buildPresetName
        } else {
            # Fallback for presets without a matching build preset (e.g. wasm).
            $binaryDir = Join-Path $repoRoot ("build\" + $Preset)
            & $cmake --build $binaryDir --config $Config
        }
        if ($LASTEXITCODE -ne 0) { throw "cmake build failed (exit $LASTEXITCODE)." }

        # --- 3) Tests (optional) ---------------------------------------------
        if ($RunTests) {
            Write-Host '[build_cpp] [3/3] ctest...'
            $ctest = Resolve-CtestExe -CmakeExePath $cmake
            if (-not $ctest) {
                throw "ctest.exe was not found next to cmake ('$cmake') nor on PATH."
            }
            $testPresets = Get-PresetKindNames -PresetsJsonPath $presetsJson -Kind 'testPresets'
            $testPresetName = "{0}-{1}" -f $Preset, $Config.ToLowerInvariant()
            if ($testPresets -contains $testPresetName) {
                & $ctest --preset $testPresetName
            } else {
                $binaryDir = Join-Path $repoRoot ("build\" + $Preset)
                & $ctest --test-dir $binaryDir -C $Config --output-on-failure
            }
            if ($LASTEXITCODE -ne 0) { throw "ctest failed (exit $LASTEXITCODE)." }
        } else {
            Write-Host '[build_cpp] [3/3] ctest skipped (-RunTests not set).'
        }
    } finally {
        Pop-Location
    }

    # --- Report the produced DLL (multi-config: bin\<Config>; single: bin\) ----
    $candidates = @(
        (Join-Path $repoRoot "build\$Preset\bin\$Config\wb_core.dll"),
        (Join-Path $repoRoot "build\$Preset\bin\wb_core.dll")
    )
    $dll = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($dll) {
        $size = (Get-Item -LiteralPath $dll).Length
        Write-Host ("[build_cpp] OK: wb_core.dll ({0:N0} bytes) -> {1}" -f $size, $dll) -ForegroundColor Green
        Write-Host ("[build_cpp] The Flutter Windows build picks it up automatically " +
                    "(wb_core_dll_deploy target in apps/desktop/windows/CMakeLists.txt).")
        exit 0
    } else {
        Write-Host ("[build_cpp] WARNING: build finished but wb_core.dll was not found under " +
                    "build\$Preset\bin\$Config. Check the build preset layout.") -ForegroundColor Yellow
        exit 1
    }
} catch {
    Write-Host ("[build_cpp] ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
