<#
.SYNOPSIS
    Compiles the native FedUpDate.UI desktop executable.
.DESCRIPTION
    Dynamically discovers the newest C# compiler (csc.exe), WPF reference assemblies,
    and WebView2 libraries with zero hardcoded version paths.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Find-LatestCSharpCompiler {
    # 1. Check in PATH
    $pathCsc = Get-Command "csc.exe" -ErrorAction SilentlyContinue
    if ($pathCsc) { return $pathCsc.Source }

    # 2. Check Visual Studio / Build Tools Roslyn installations
    $progFiles = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($pf in $progFiles) {
        $vsRoot = Join-Path $pf "Microsoft Visual Studio"
        if (Test-Path $vsRoot) {
            $roslynCandidates = Get-ChildItem -Path $vsRoot -Filter "csc.exe" -Recurse -Depth 7 -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($roslynCandidates) {
                return $roslynCandidates[0].FullName
            }
        }
    }

    # 3. Check .NET Framework 64-bit and 32-bit directories (newest version first)
    $netRoots = @(
        (Join-Path $env:SystemRoot "Microsoft.NET\Framework64"),
        (Join-Path $env:SystemRoot "Microsoft.NET\Framework")
    )
    foreach ($root in $netRoots) {
        if (Test-Path $root) {
            $versions = Get-ChildItem -Path $root -Directory -Filter "v4.*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending
            foreach ($ver in $versions) {
                $csc = Join-Path $ver.FullName "csc.exe"
                if (Test-Path $csc) {
                    return $csc
                }
            }
        }
    }

    # 4. Fallback to active CLR runtime directory
    $runtimeDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $runtimeCsc = Join-Path $runtimeDir "csc.exe"
    if (Test-Path $runtimeCsc) { return $runtimeCsc }

    return $null
}

function Find-WpfDirectory {
    param([string]$CscPath)

    if ($CscPath) {
        $cscDir = Split-Path -Parent $CscPath
        $wpfCandidate = Join-Path $cscDir "WPF"
        if (Test-Path (Join-Path $wpfCandidate "PresentationFramework.dll")) {
            return $wpfCandidate
        }
    }

    $netRoots = @(
        (Join-Path $env:SystemRoot "Microsoft.NET\Framework64"),
        (Join-Path $env:SystemRoot "Microsoft.NET\Framework")
    )
    foreach ($root in $netRoots) {
        if (Test-Path $root) {
            $versions = Get-ChildItem -Path $root -Directory -Filter "v4.*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending
            foreach ($ver in $versions) {
                $wpf = Join-Path $ver.FullName "WPF"
                if (Test-Path (Join-Path $wpf "PresentationFramework.dll")) {
                    return $wpf
                }
            }
        }
    }

    return $null
}

# Resolve project directories relatively
$scriptDir = $PSScriptRoot
$guiDir = Split-Path -Parent $scriptDir
if (-not (Test-Path (Join-Path $guiDir "src\Program.cs"))) {
    $guiDir = $scriptDir
}

$binDir = Join-Path $guiDir "bin"
$srcFile = Join-Path $guiDir "src\Program.cs"
$outFile = Join-Path $binDir "FedUpDate.UI.exe"

if (-not (Test-Path $srcFile)) {
    Write-Error "Source file not found at: $srcFile"
    exit 1
}

# Dynamically discover compiler and WPF assemblies
$cscExe = Find-LatestCSharpCompiler
if (-not $cscExe) {
    Write-Error "No C# compiler (csc.exe) could be detected on this system."
    exit 1
}

$wpfDir = Find-WpfDirectory -CscPath $cscExe
if (-not $wpfDir) {
    Write-Error "No WPF reference assemblies (PresentationFramework.dll) could be detected."
    exit 1
}

Write-Host "[BUILD] Detected C# Compiler: $cscExe" -ForegroundColor DarkCyan
Write-Host "[BUILD] Detected WPF Reference Path: $wpfDir" -ForegroundColor DarkCyan

# Stop running instances to release file locks
Write-Host "[BUILD] Stopping any running UI instances..." -ForegroundColor Cyan
Stop-Process -Name "FedUpDate.UI" -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

$refAssemblies = @(
    (Join-Path $wpfDir "PresentationFramework.dll"),
    (Join-Path $wpfDir "PresentationCore.dll"),
    (Join-Path $wpfDir "WindowsBase.dll"),
    "System.Xaml.dll",
    "System.dll",
    "System.Core.dll",
    (Join-Path $binDir "Microsoft.Web.WebView2.Wpf.dll"),
    (Join-Path $binDir "Microsoft.Web.WebView2.Core.dll")
)

$icoFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "assets\desktop\app.ico"

$argsList = @(
    "/target:winexe",
    "/platform:x64",
    "/optimize+",
    "/out:`"$outFile`""
)

if (Test-Path $icoFile) {
    $argsList += "/win32icon:`"$icoFile`""
}

foreach ($ref in $refAssemblies) {
    $argsList += "/r:`"$ref`""
}

$argsList += "`"$srcFile`""

Write-Host "[BUILD] Compiling $srcFile -> $outFile..." -ForegroundColor Cyan

$process = Start-Process -FilePath $cscExe -ArgumentList ($argsList -join " ") -NoNewWindow -Wait -PassThru

if ($process.ExitCode -eq 0 -and (Test-Path $outFile)) {
    Write-Host "[OK] FedUpDate.UI.exe compiled successfully." -ForegroundColor Green
} else {
    Write-Error "[FAIL] Compilation failed with exit code $($process.ExitCode)."
    exit $process.ExitCode
}
