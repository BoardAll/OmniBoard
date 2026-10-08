# ============================================================================
# build_openssl.ps1 — build a static OpenSSL for the whiteboard third-party
# stack (desktop sioxx TLS support; see docs/modules/17-build-release.md).
# ============================================================================
# Invoked by core/third_party/CMakeLists.txt during CMake configure when no
# system OpenSSL is available and the local prefix has not been produced yet.
# Produces <InstallDir>\include + <InstallDir>\lib, consumed by CMake's
# FindOpenSSL via OPENSSL_ROOT_DIR.
#
# Host requirements:
#   - Visual Studio 2022 C++ toolset (cl / nmake) + Windows SDK. Discovered
#     via vswhere first, then standard install locations; no vcvars needed.
#   - A native Windows perl (Strawberry Perl). Git-for-Windows MSYS perl is
#     rejected by OpenSSL's Configure ("doesn't produce Windows like paths").
#     Resolution order: -PerlExe, $env:WB_PERL, standard install locations,
#     then PATH (each candidate must report $^O = MSWin32).
#   - No NASM required: configured with no-asm (only assembly fast paths are
#     omitted; TLS/crypto still work -- acceptable for a Socket.IO client).
#
# The script is idempotent: it exits 0 immediately when the install prefix
# already contains include\openssl\ssl.h + lib\libssl.lib (or ssl.lib).
# Use -Force to rebuild from a clean state (re-runs Configure + nmake).
#
# Exit codes: 0 = success (or already satisfied), 1 = failure.
# ============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    # Unpacked OpenSSL source tree (directory containing the Configure script).
    [Parameter(Mandatory = $true)][string]$SourceDir,

    # Install prefix to populate (include\ + lib\). Consumed by FindOpenSSL.
    [Parameter(Mandatory = $true)][string]$InstallDir,

    # Directory for configure/build/install logs.
    [Parameter(Mandatory = $true)][string]$LogDir,

    # Explicit perl.exe path (default: $env:WB_PERL, then standard locations, then PATH).
    [string]$PerlExe,

    # Re-run configure/build/install even if the prefix already looks complete.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-InstallComplete {
    param([string]$Prefix)
    if (-not (Test-Path -LiteralPath (Join-Path $Prefix 'include\openssl\ssl.h'))) {
        return $false
    }
    # OpenSSL 3.x installs libssl/libcrypto; accept historical names as well.
    foreach ($name in @('libssl.lib', 'ssl.lib')) {
        if (Test-Path -LiteralPath (Join-Path $Prefix "lib\$name")) { return $true }
    }
    return $false
}

function Find-VsRoot {
    # Prefer vswhere (present on VS2017+ installs and CI images).
    $vswhere = $null
    if (${env:ProgramFiles(x86)}) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    if ($vswhere -and (Test-Path -LiteralPath $vswhere)) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $vswhere -latest -products * `
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                -property installationPath
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($code -eq 0 -and $out) {
            $first = @($out)[0].ToString().Trim()
            if ($first -and (Test-Path -LiteralPath $first)) { return $first }
        }
    }
    # Fallback: standard install locations (VS2022).
    foreach ($cand in @(
            'C:\Program Files\Microsoft Visual Studio\2022\Community',
            'C:\Program Files\Microsoft Visual Studio\2022\Professional',
            'C:\Program Files\Microsoft Visual Studio\2022\Enterprise',
            'C:\Program Files\Microsoft Visual Studio\2022\BuildTools')) {
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    throw 'Visual Studio 2022 with the C++ toolset was not found (vswhere and standard locations).'
}

function Get-VsTools {
    $vsRoot = Find-VsRoot
    $msvc = Get-ChildItem (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $msvc) { throw "MSVC toolset not found under '$vsRoot\VC\Tools\MSVC'." }

    $sdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
    $sdkInc = Get-ChildItem (Join-Path $sdkRoot 'Include') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $sdkBin = Get-ChildItem (Join-Path $sdkRoot 'bin') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $sdkInc -or -not $sdkBin) { throw "Windows SDK not found under '$sdkRoot'." }

    return [pscustomobject]@{
        MsvcRoot = $msvc.FullName
        ClDir    = Join-Path $msvc.FullName 'bin\Hostx64\x64'
        SdkRoot  = $sdkRoot
        SdkInc   = $sdkInc.Name
        SdkBin   = $sdkBin.Name
    }
}

function Test-NativeWindowsPerl {
    param([string]$Exe)
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $false }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $osName = & $Exe -e 'print $^O' 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { return $false }
    # MSYS/Git perl reports "msys" and is rejected by OpenSSL's Configure.
    return (($osName | Out-String).Trim() -eq 'MSWin32')
}

function Resolve-Perl {
    param([string]$Override)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Override) { $candidates.Add($Override) }
    if ($env:WB_PERL) { $candidates.Add($env:WB_PERL) }
    # Strawberry Perl: standard install and the conventional portable drop used
    # on dev machines (mirrors the WB_CMAKE resolution pattern: no hard-coded
    # machine-specific paths beyond well-known defaults, override via WB_PERL).
    $candidates.Add('C:\Strawberry\perl\bin\perl.exe')
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'wb-tools\strawberry\perl\bin\perl.exe'))
    }
    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Strawberry\perl\bin\perl.exe'))
    }
    Get-Command perl.exe -All -ErrorAction SilentlyContinue |
        ForEach-Object { $candidates.Add($_.Source) }

    foreach ($cand in $candidates) {
        if (Test-NativeWindowsPerl -Exe $cand) {
            return (Resolve-Path -LiteralPath $cand).Path
        }
    }
    throw ('No native Windows perl found. Building OpenSSL requires Strawberry Perl ' +
           '(https://strawberryperl.com). Install it, set WB_PERL to perl.exe, ' +
           'or pass -PerlExe. (Git-for-Windows MSYS perl is not supported.)')
}

function Set-MsvcEnvironment {
    param([object]$Tools, [string]$PerlExePath)
    $perlDir = Split-Path -Parent $PerlExePath
    # cl/nmake first; perl dir so the generated Makefile can invoke `perl`.
    $env:PATH = "$($Tools.ClDir);$($Tools.SdkRoot)\bin\$($Tools.SdkBin)\x64;$perlDir;" + $env:PATH
    $env:INCLUDE = ("$($Tools.MsvcRoot)\include;" +
        "$($Tools.SdkRoot)\Include\$($Tools.SdkInc)\ucrt;" +
        "$($Tools.SdkRoot)\Include\$($Tools.SdkInc)\um;" +
        "$($Tools.SdkRoot)\Include\$($Tools.SdkInc)\shared;" +
        "$($Tools.SdkRoot)\Include\$($Tools.SdkInc)\winrt")
    $env:LIB = ("$($Tools.MsvcRoot)\lib\x64;" +
        "$($Tools.SdkRoot)\Lib\$($Tools.SdkInc)\ucrt\x64;" +
        "$($Tools.SdkRoot)\Lib\$($Tools.SdkInc)\um\x64")
}

function Invoke-Native {
    # Runs a native command, tees the full output to a log file, shows a tail,
    # and returns the exit code. $ErrorActionPreference stays non-terminating
    # locally so native stderr does not abort the script on PowerShell 5.1.
    param(
        [string]$LogFile,
        [int]$TailLines = 20,
        [scriptblock]$Body
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Body 2>&1 | Tee-Object -FilePath $LogFile | Out-Null
        $code = $script:LastExitCode
    } finally {
        $ErrorActionPreference = $prev
    }
    Write-Host ("[openssl_build]   log: $LogFile (tail $TailLines)")
    Get-Content -LiteralPath $LogFile -Tail $TailLines | ForEach-Object { Write-Host ("[openssl_build]   | " + $_) }
    return $code
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    $SourceDir = Resolve-FullPath $SourceDir
    $InstallDir = Resolve-FullPath $InstallDir
    $LogDir = Resolve-FullPath $LogDir
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'Configure'))) {
        throw "OpenSSL source tree not found at '$SourceDir' (expected a Configure script)."
    }

    if ((Test-InstallComplete -Prefix $InstallDir) -and -not $Force) {
        Write-Host ("[openssl_build] Install prefix already complete, nothing to do: $InstallDir")
        exit 0
    }

    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()

    $tools = Get-VsTools
    $perl = Resolve-Perl -Override $PerlExe
    Set-MsvcEnvironment -Tools $tools -PerlExePath $perl

    $nmake = Join-Path $tools.ClDir 'nmake.exe'
    $cl = Join-Path $tools.ClDir 'cl.exe'
    if (-not (Test-Path -LiteralPath $nmake) -or -not (Test-Path -LiteralPath $cl)) {
        throw "cl.exe / nmake.exe missing under '$($tools.ClDir)'."
    }

    Write-Host "[openssl_build] VS MSVC : $($tools.MsvcRoot)"
    Write-Host "[openssl_build] SDK     : $($tools.SdkRoot) (inc $($tools.SdkInc))"
    Write-Host "[openssl_build] perl    : $perl"
    Write-Host "[openssl_build] source  : $SourceDir"
    Write-Host "[openssl_build] install : $InstallDir"

    Push-Location $SourceDir
    try {
        # --- 1) Configure ----------------------------------------------------
        $makefile = Join-Path $SourceDir 'makefile'
        if ($Force -or -not (Test-Path -LiteralPath $makefile)) {
            Write-Host '[openssl_build] [1/3] Configure...'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $script:LastExitCode = 0
            $code = Invoke-Native -LogFile (Join-Path $LogDir 'openssl-configure.log') -TailLines 15 -Body {
                & $perl Configure VC-WIN64A no-asm no-shared no-tests no-apps no-docs `
                    "--prefix=$InstallDir" "--openssldir=$InstallDir\ssl"
                $script:LastExitCode = $LASTEXITCODE
            }
            $sw.Stop()
            Write-Host ("[openssl_build] Configure exit={0} elapsed={1:N1}s" -f $code, $sw.Elapsed.TotalSeconds)
            if ($code -ne 0) { throw "OpenSSL Configure failed (exit $code), see $LogDir\openssl-configure.log" }
        } else {
            Write-Host '[openssl_build] [1/3] Configure skipped (makefile present; use -Force to redo).'
        }

        # --- 2) Build (nmake, incremental) -----------------------------------
        Write-Host '[openssl_build] [2/3] Build (nmake)...'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $script:LastExitCode = 0
        $code = Invoke-Native -LogFile (Join-Path $LogDir 'openssl-build.log') -TailLines 10 -Body {
            & $nmake
            $script:LastExitCode = $LASTEXITCODE
        }
        $sw.Stop()
        Write-Host ("[openssl_build] Build exit={0} elapsed={1:N1}s" -f $code, $sw.Elapsed.TotalSeconds)
        if ($code -ne 0) { throw "OpenSSL build failed (exit $code), see $LogDir\openssl-build.log" }

        # --- 3) Install (install_sw) -----------------------------------------
        Write-Host '[openssl_build] [3/3] Install (nmake install_sw)...'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $script:LastExitCode = 0
        $code = Invoke-Native -LogFile (Join-Path $LogDir 'openssl-install.log') -TailLines 10 -Body {
            & $nmake install_sw
            $script:LastExitCode = $LASTEXITCODE
        }
        $sw.Stop()
        Write-Host ("[openssl_build] Install exit={0} elapsed={1:N1}s" -f $code, $sw.Elapsed.TotalSeconds)
        if ($code -ne 0) { throw "OpenSSL install failed (exit $code), see $LogDir\openssl-install.log" }
    } finally {
        Pop-Location
    }

    # --- Verify the produced prefix (FindOpenSSL must be able to consume it) --
    if (-not (Test-InstallComplete -Prefix $InstallDir)) {
        throw ("OpenSSL install finished but the expected files are missing under " +
               "'$InstallDir' (include\openssl\ssl.h + lib\libssl.lib).")
    }
    $libs = (Get-ChildItem (Join-Path $InstallDir 'lib') -Filter '*.lib' |
        Select-Object -ExpandProperty Name) -join ', '
    Write-Host "[openssl_build] libs    : $libs"

    $totalWatch.Stop()
    Write-Host ("[openssl_build] OK: OpenSSL prefix ready in {0:N1}s -> {1}" -f `
        $totalWatch.Elapsed.TotalSeconds, $InstallDir)
    exit 0
} catch {
    Write-Host ("[openssl_build] ERROR: " + $_.Exception.Message)
    exit 1
}
