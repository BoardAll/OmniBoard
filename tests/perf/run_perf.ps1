<#
run_perf.ps1 - whiteboard performance-test wrapper (design doc "testing plan" 10.4).

Wires the three commands from the design section:
  1. C++ benchmarks : build/windows-x64/bin/Release/wb_benchmarks.exe
  2. Flutter perf   : flutter test --profile integration_test/app_test.dart
  3. Web perf       : lighthouse http://localhost:8080 --output=json ...

Missing tooling is reported as SKIP (exit code stays 0) unless -Strict is set.
Use -DryRun to print the planned commands without executing anything.

NOTE: strings in this file stay ASCII on purpose so that Windows PowerShell 5.1
(which reads non-BOM files as ANSI) parses it identically to pwsh 7.
#>

[CmdletBinding()]
param(
    [string]$FlutterTarget = 'integration_test/app_test.dart',
    [switch]$DryRun,
    [switch]$SkipCpp,
    [switch]$SkipFlutter,
    [switch]$SkipWeb,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$BenchExe = Join-Path $RepoRoot 'build\windows-x64\bin\Release\wb_benchmarks.exe'
$DesktopDir = Join-Path $RepoRoot 'apps\desktop'
$OutDir = Join-Path $PSScriptRoot 'out'

$script:Executed = 0
$script:Skipped = 0

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host ("=== " + $Text + " ===")
}

function Write-Skip([string]$Reason) {
    $script:Skipped += 1
    Write-Host ("SKIP: " + $Reason)
}

function Resolve-FlutterBin {
    if ($env:WB_FLUTTER) { return $env:WB_FLUTTER }
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = 'E:\code\flutter-sdk\flutter\bin\flutter.bat'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

# --- Step 1: C++ benchmarks -------------------------------------------------
Write-Head 'Step 1/3: C++ benchmarks'
if ($SkipCpp) {
    Write-Skip 'disabled by -SkipCpp'
} elseif (-not (Test-Path -LiteralPath $BenchExe)) {
    Write-Skip ("benchmark binary not found: " + $BenchExe)
    Write-Host '  build it first: cd core; cmake --preset windows-x64 -DWB_BUILD_BENCHMARKS=ON; cmake --build build/windows-x64'
} elseif ($DryRun) {
    Write-Host ("DRY-RUN: " + $BenchExe + " > out\benchmarks.log")
} else {
    $log = Join-Path $OutDir 'benchmarks.log'
    Write-Host ("running: " + $BenchExe)
    $global:LASTEXITCODE = 0
    & $BenchExe 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw ("benchmarks failed with exit code " + $LASTEXITCODE)
    }
    $script:Executed += 1
    Write-Host ("OK: " + $log)
}

# --- Step 2: Flutter perf test ----------------------------------------------
Write-Head 'Step 2/3: Flutter perf test'
$flutterBin = Resolve-FlutterBin
if ($SkipFlutter) {
    Write-Skip 'disabled by -SkipFlutter'
} elseif (-not $flutterBin) {
    Write-Skip 'flutter not found (set WB_FLUTTER or add flutter to PATH)'
} elseif ($DryRun) {
    Write-Host ("DRY-RUN: cd apps\desktop; " + $flutterBin + " test --profile " + $FlutterTarget)
} else {
    Write-Host ("running: flutter test --profile " + $FlutterTarget)
    Push-Location $DesktopDir
    try {
        & $flutterBin test --profile $FlutterTarget
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) {
        throw ("flutter perf test failed with exit code " + $code)
    }
    $script:Executed += 1
    Write-Host 'OK: flutter perf test passed'
}

# --- Step 3: Web performance (Lighthouse) -----------------------------------
Write-Head 'Step 3/3: Web perf (Lighthouse)'
$lighthouse = Get-Command lighthouse -ErrorAction SilentlyContinue
if ($SkipWeb) {
    Write-Skip 'disabled by -SkipWeb'
} elseif (-not $lighthouse) {
    Write-Skip 'lighthouse CLI not found (npm i -g lighthouse)'
    Write-Host '  then: flutter run -d web-server --web-port 8080 (in apps/web)'
} else {
    $serverUp = $false
    try {
        $null = Invoke-WebRequest -Uri 'http://localhost:8080' -UseBasicParsing -TimeoutSec 3
        $serverUp = $true
    } catch {
        $serverUp = $false
    }
    if (-not $serverUp) {
        Write-Skip 'no dev server on http://localhost:8080 (start: flutter run -d web-server --web-port 8080)'
    } elseif ($DryRun) {
        Write-Host ("DRY-RUN: lighthouse http://localhost:8080 --output=json --output-path=" + (Join-Path $OutDir 'lighthouse.json'))
    } else {
        $report = Join-Path $OutDir 'lighthouse.json'
        Write-Host 'running: lighthouse http://localhost:8080'
        & $lighthouse.Source http://localhost:8080 --output=json --output-path=$report --quiet
        if ($LASTEXITCODE -ne 0) {
            throw ("lighthouse failed with exit code " + $LASTEXITCODE)
        }
        $script:Executed += 1
        Write-Host ("OK: " + $report)
    }
}

# --- Summary ----------------------------------------------------------------
Write-Head 'Summary'
Write-Host ("executed: " + $script:Executed + ", skipped: " + $script:Skipped + ", dry-run: " + [bool]$DryRun)
if ($Strict -and $script:Skipped -gt 0) {
    Write-Host 'STRICT: skipped steps are failures in -Strict mode'
    exit 1
}
exit 0
