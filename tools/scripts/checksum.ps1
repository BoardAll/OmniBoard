# ============================================================================
# checksum.ps1 — generate SHA256 checksums for release artifacts.
# ============================================================================
# Implements docs/构建打包与发布设计.md §15.4 (checksums), in the sha256sum
# format so files can be verified with standard tooling:
#
#   <sha256> *<filename>
#
# Usage:
#   tools\scripts\checksum.ps1                          # dist\ -> dist\SHA256SUMS
#   tools\scripts\checksum.ps1 -Path dist -PerFile      # also <file>.sha256
#   tools\scripts\checksum.ps1 -Path build\wasm\dist -Output $env:TEMP\SHA256SUMS
#   tools\scripts\checksum.ps1 -Path dist -Recurse
#
# Behaviour:
#   * Reads only; never deletes or overwrites anything except the output file.
#   * Skips the output file itself, existing *.sha256 files and SHA256SUMS so
#     repeated runs stay deterministic.
#   * Missing directory -> prints a notice and exits 0 (nothing to do), unless
#     -Strict is given.
#
# Exit codes: 0 = success (or nothing to do), 1 = failure.
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Directory to generate checksums for (repo-relative or absolute).
    [string]$Path = 'dist',

    # Output file (default: <Path>\SHA256SUMS).
    [string]$Output,

    # Also write a per-file <name>.sha256 next to each artifact.
    [switch]$PerFile,

    # Recurse into subdirectories.
    [switch]$Recurse,

    # Fail (exit 1) instead of skipping when -Path does not exist.
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

# UTF-8 without BOM (consumers like sha256sum / CI tools dislike a BOM).
function Write-TextNoBom {
    param([string]$FilePath, [string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($FilePath, $Content, $encoding)
}

try {
    $repoRoot = Get-RepoRoot
    $targetDir = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }

    if (-not (Test-Path -LiteralPath $targetDir)) {
        Write-Host ("[checksum] Directory not found: " + $targetDir + ' — nothing to do.') -ForegroundColor Yellow
        if ($Strict) { exit 1 } else { exit 0 }
    }
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        throw "Path is not a directory: $targetDir"
    }

    if (-not $Output) { $Output = Join-Path $targetDir 'SHA256SUMS' }
    elseif (-not [System.IO.Path]::IsPathRooted($Output)) { $Output = Join-Path $repoRoot $Output }
    $outputFileName = Split-Path -Leaf $Output

    # @() keeps the result an array when exactly one file matches (a bare
    # FileInfo has no .Count under Set-StrictMode and would fail below).
    $files = @(Get-ChildItem -LiteralPath $targetDir -File -Recurse:$Recurse |
        Where-Object {
            $_.Name -ne $outputFileName -and
            $_.Name -ne 'SHA256SUMS' -and
            -not $_.Name.EndsWith('.sha256')
        } |
        Sort-Object -Property Name)

    if ($files.Count -eq 0) {
        Write-Host ("[checksum] No files to checksum in " + $targetDir + ' — nothing to do.')
        exit 0
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add(("{0} *{1}" -f $hash, $file.Name))
        if ($PerFile) {
            Write-TextNoBom -FilePath ($file.FullName + '.sha256') -Content ($hash + ' *' + $file.Name + "`n")
        }
    }

    $outputDir = Split-Path -Parent $Output
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    Write-TextNoBom -FilePath $Output -Content (($lines -join "`n") + "`n")

    # Self-verify: re-read the written file from disk and re-check every
    # entry against a fresh hash (catches IO/encoding problems on write).
    $verifyOk = $true
    $recordedLines = @()
    if (Test-Path -LiteralPath $Output) {
        $recordedLines = @(Get-Content -LiteralPath $Output -Encoding UTF8)
    }
    foreach ($file in $files) {
        $expected = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $recorded = ($recordedLines | Where-Object { $_.EndsWith(' *' + $file.Name) } | Select-Object -First 1)
        if (-not $recorded -or -not $recorded.StartsWith($expected)) { $verifyOk = $false }
    }

    Write-Host ("[checksum] Wrote {0} entries -> {1}" -f $files.Count, $Output) -ForegroundColor Green
    if ($PerFile) { Write-Host '[checksum] Per-file .sha256 files written.' }
    if ($verifyOk) {
        Write-Host '[checksum] Self-verification passed.' -ForegroundColor Green
        exit 0
    } else {
        Write-Host '[checksum] Self-verification FAILED.' -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host ("[checksum] ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
