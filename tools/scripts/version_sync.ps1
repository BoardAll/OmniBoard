# ============================================================================
# version_sync.ps1 — check / update the version across the monorepo.
# ============================================================================
# Implements docs/构建打包与发布设计.md §16.2/§16.3 (version files and sync).
#
# Default mode is -Check: it only reads files, prints a consistency table and
# exits non-zero on mismatches. -Write is opt-in and edits files.
#
# Usage:
#   tools\scripts\version_sync.ps1                       # check (read-only)
#   tools\scripts\version_sync.ps1 -Check
#   tools\scripts\version_sync.ps1 -Write                # update from VERSION
#   tools\scripts\version_sync.ps1 -Write -Version 1.1.0 -BuildNumber 5
#
# Checked targets:
#   * VERSION (repository root; the single source of truth)
#   * apps/*/pubspec.yaml, packages/*/pubspec.yaml, platform/*/pubspec.yaml
#     (`version:` — the `+build` suffix is allowed and ignored for comparison)
#   * services/*/package.json (`"version"`)
#   * CMakeLists.txt (root) and core/CMakeLists.txt (`project(... VERSION x)`)
#
# -Write mode:
#   * updates all of the above to the target version (VERSION file included
#     unless -SkipVersionFile), keeping each pubspec's existing +build suffix
#     unless -BuildNumber is given.
#
# Exit codes: 0 = consistent (check) / updated (write), 1 = mismatch or error.
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Check mode (default; read-only).
    [switch]$Check,

    # Write mode: update files to the target version.
    [switch]$Write,

    # Target version for -Write (default: content of the VERSION file).
    [string]$Version,

    # Build number for pubspec `+build` when -Write is used.
    [int]$BuildNumber = 0,

    # -Write only: do not touch the VERSION file itself.
    [switch]$SkipVersionFile,

    # -Write only: do not touch CMake project() VERSION lines.
    [switch]$SkipCmake
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-CoreVersion {
    param([string]$Raw)
    $trimmed = ($Raw -replace '^v', '').Trim()
    $core = ($trimmed -split '\+')[0]
    if ($core -notmatch '^\d+\.\d+\.\d+$') { return $null }
    return $core
}

# UTF-8 without BOM — keeps the files diff-friendly and pubspec-safe.
function Write-TextNoBom {
    param([string]$Path, [string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

try {
    if ($Check -and $Write) { throw '-Check and -Write are mutually exclusive (default is -Check).' }
    $mode = if ($Write) { 'Write' } else { 'Check' }

    $repoRoot = Get-RepoRoot
    Write-Host "[version_sync] Repository: $repoRoot"
    Write-Host "[version_sync] Mode      : $mode"

    $versionFile = Join-Path $repoRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile)) { throw "VERSION file not found: $versionFile" }
    $fileVersion = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
    $coreVersion = Get-CoreVersion -Raw $fileVersion
    if (-not $coreVersion) {
        throw "VERSION file content is not MAJOR.MINOR.PATCH: '$fileVersion'"
    }

    # ------------------------------------------------------------------------
    # Collect all version-bearing files.
    # ------------------------------------------------------------------------
    $pubspecs = @()
    foreach ($root in @('apps', 'packages', 'platform')) {
        $dir = Join-Path $repoRoot $root
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object {
            $candidate = Join-Path $_.FullName 'pubspec.yaml'
            if (Test-Path -LiteralPath $candidate) { $pubspecs += $candidate }
        }
    }
    # apps/desktop and apps/web are the two we care about most; keep the rest.
    $packageJsons = @()
    $servicesDir = Join-Path $repoRoot 'services'
    if (Test-Path -LiteralPath $servicesDir) {
        Get-ChildItem -LiteralPath $servicesDir -Directory | ForEach-Object {
            $candidate = Join-Path $_.FullName 'package.json'
            if (Test-Path -LiteralPath $candidate) { $packageJsons += $candidate }
        }
    }
    $cmakeFiles = @(
        (Join-Path $repoRoot 'CMakeLists.txt'),
        (Join-Path $repoRoot 'core\CMakeLists.txt')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    if ($mode -eq 'Check') {
        # ---------------------------------------------------------------------
        # Check: report a table, exit 1 on any mismatch.
        # ---------------------------------------------------------------------
        $rows = @()
        $mismatches = 0

        Write-Host ''
        Write-Host ("[version_sync] Expected core version: {0} (VERSION file: {1})" -f $coreVersion, $fileVersion)
        Write-Host ''

        foreach ($p in $pubspecs) {
            $rel = $p.Substring($repoRoot.Length + 1)
            $line = Select-String -LiteralPath $p -Pattern '^version:\s*(.+)$' | Select-Object -First 1
            if (-not $line) {
                $rows += [pscustomobject]@{ File = $rel; Found = '<no version:>'; Status = 'MISMATCH' }
                $mismatches++
                continue
            }
            $found = $line.Matches[0].Groups[1].Value.Trim()
            $foundCore = Get-CoreVersion -Raw $found
            $ok = ($foundCore -eq $coreVersion)
            if (-not $ok) { $mismatches++ }
            $rows += [pscustomobject]@{ File = $rel; Found = $found; Status = if ($ok) { 'OK' } else { 'MISMATCH' } }
        }

        foreach ($j in $packageJsons) {
            $rel = $j.Substring($repoRoot.Length + 1)
            $json = Get-Content -LiteralPath $j -Raw -Encoding UTF8 | ConvertFrom-Json
            $found = [string]$json.version
            $foundCore = Get-CoreVersion -Raw $found
            $ok = ($foundCore -eq $coreVersion)
            if (-not $ok) { $mismatches++ }
            $rows += [pscustomobject]@{ File = $rel; Found = $found; Status = if ($ok) { 'OK' } else { 'MISMATCH' } }
        }

        foreach ($c in $cmakeFiles) {
            $rel = $c.Substring($repoRoot.Length + 1)
            $line = Select-String -LiteralPath $c -Pattern 'project\(\s*\S+\s+VERSION\s+(\d+\.\d+\.\d+)' | Select-Object -First 1
            if (-not $line) {
                $rows += [pscustomobject]@{ File = $rel; Found = '<no project() VERSION>'; Status = 'INFO' }
                continue
            }
            $found = $line.Matches[0].Groups[1].Value
            $ok = ($found -eq $coreVersion)
            if (-not $ok) { $mismatches++ }
            $rows += [pscustomobject]@{ File = $rel; Found = $found; Status = if ($ok) { 'OK' } else { 'MISMATCH' } }
        }

        $rows | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host ("[version_sync] Checked {0} file(s): {1} mismatch(es)." -f $rows.Count, $mismatches)
        if ($mismatches -gt 0) {
            Write-Host ('[version_sync] INCONSISTENT — run with -Write after bumping the VERSION file, ' +
                        'or fix the files above manually.') -ForegroundColor Yellow
            exit 1
        }
        Write-Host '[version_sync] All versions are consistent.' -ForegroundColor Green
        exit 0
    }

    # -------------------------------------------------------------------------
    # Write mode (explicit opt-in): update every target to the wanted version.
    # -------------------------------------------------------------------------
    $targetVersion = $Version
    if (-not $targetVersion) { $targetVersion = $coreVersion }
    $targetCore = Get-CoreVersion -Raw $targetVersion
    if (-not $targetCore) { throw "Target version '$targetVersion' is not MAJOR.MINOR.PATCH." }

    $changed = 0
    if (-not $SkipVersionFile) {
        if ($fileVersion -ne $targetCore) {
            Write-TextNoBom -Path $versionFile -Content ($targetCore + "`n")
            Write-Host ("[version_sync] Wrote VERSION: {0} -> {1}" -f $fileVersion, $targetCore)
            $changed++
        }
    }

    foreach ($p in $pubspecs) {
        $rel = $p.Substring($repoRoot.Length + 1)
        $content = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        $line = Select-String -LiteralPath $p -Pattern '^version:\s*(.+)$' | Select-Object -First 1
        if (-not $line) { Write-Host ("[version_sync] SKIP (no version:): " + $rel); continue }
        $oldRaw = $line.Matches[0].Groups[1].Value.Trim()
        $oldParts = $oldRaw -split '\+'
        $build = if ($BuildNumber -gt 0) { $BuildNumber } elseif ($oldParts.Count -gt 1) { $oldParts[1] } else { '1' }
        $newRaw = "{0}+{1}" -f $targetCore, $build
        if ($oldRaw -eq $newRaw) { continue }
        $updated = $content -replace '(?m)^version:\s*.+$', ("version: " + $newRaw)
        Write-TextNoBom -Path $p -Content $updated
        Write-Host ("[version_sync] Updated {0}: {1} -> {2}" -f $rel, $oldRaw, $newRaw)
        $changed++
    }

    foreach ($j in $packageJsons) {
        $rel = $j.Substring($repoRoot.Length + 1)
        $content = Get-Content -LiteralPath $j -Raw -Encoding UTF8
        $old = [string]((Get-Content -LiteralPath $j -Raw -Encoding UTF8 | ConvertFrom-Json).version)
        if ($old -eq $targetCore) { continue }
        $updated = $content -replace '"version":\s*"[^"]*"', ('"version": "' + $targetCore + '"')
        Write-TextNoBom -Path $j -Content $updated
        Write-Host ("[version_sync] Updated {0}: {1} -> {2}" -f $rel, $old, $targetCore)
        $changed++
    }

    if (-not $SkipCmake) {
        foreach ($c in $cmakeFiles) {
            $rel = $c.Substring($repoRoot.Length + 1)
            $content = Get-Content -LiteralPath $c -Raw -Encoding UTF8
            $updated = $content -replace '(?m)(project\(\s*\S+\s+VERSION\s+)\d+\.\d+\.\d+', ('${1}' + $targetCore)
            if ($updated -ne $content) {
                Write-TextNoBom -Path $c -Content $updated
                Write-Host ("[version_sync] Updated {0}: project() VERSION -> {1}" -f $rel, $targetCore)
                $changed++
            }
        }
    }

    Write-Host ("[version_sync] Write complete: {0} file(s) changed (target {1})." -f $changed, $targetCore) -ForegroundColor Green
    exit 0
} catch {
    Write-Host ("[version_sync] ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
