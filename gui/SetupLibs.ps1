<#
.SYNOPSIS
    Restores the WebView2 SDK libraries required to build FedUpDate.UI.exe.
.DESCRIPTION
    Downloads the official Microsoft.Web.WebView2 NuGet package over plain HTTPS
    and extracts the managed assemblies and the native loader into gui/bin,
    alongside the compiled executable that loads them.

    A .nupkg is an ordinary ZIP archive served from a public URL, so no NuGet
    client, .NET SDK, or Visual Studio installation is required - only
    Invoke-WebRequest and Expand-Archive, both of which ship with Windows
    PowerShell.

    The installer runs this automatically before compiling the GUI, so these
    libraries are fetched from Microsoft on the machine that will use them and
    are never redistributed by this project.
.PARAMETER Version
    Specific package version to restore. Defaults to the latest stable release.
.PARAMETER Force
    Re-download and overwrite libraries that are already present.
#>

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$guiDir = $PSScriptRoot
$binDir = Join-Path $guiDir "bin"

# Managed assemblies referenced by gui/src/Program.cs, plus the native loader
# matching build.ps1's /platform:x64 target.
$managedAssemblies = @(
    "Microsoft.Web.WebView2.Core.dll",
    "Microsoft.Web.WebView2.Wpf.dll",
    "Microsoft.Web.WebView2.WinForms.dll"
)
$nativeLoader = "WebView2Loader.dll"

# Skip the download entirely when everything is already in place.
if (-not $Force) {
    $present = $true
    foreach ($dll in $managedAssemblies) {
        if (-not (Test-Path (Join-Path $binDir $dll))) { $present = $false; break }
    }
    if ($present -and -not (Test-Path (Join-Path $binDir $nativeLoader))) { $present = $false }

    if ($present) {
        Write-Host "[OK] WebView2 libraries already present. Use -Force to re-download." -ForegroundColor Gray
        return
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Resolve the newest stable version when none was requested. Prerelease builds
# carry a hyphenated suffix (for example 1.0.4181-prerelease) and are skipped.
if (-not $Version) {
    Write-Host "[INFO] Resolving latest stable Microsoft.Web.WebView2 version..." -ForegroundColor Cyan
    try {
        $index = Invoke-RestMethod -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json" -UseBasicParsing
        $stable = @($index.versions | Where-Object { $_ -notmatch '-' })
        if ($stable.Count -eq 0) { throw "No stable versions listed." }
        $Version = $stable[-1]
    } catch {
        Write-Error "Failed to query the NuGet package index: $_"
        exit 1
    }
}

$versionLower = $Version.ToLowerInvariant()
$packageUrl = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$versionLower/microsoft.web.webview2.$versionLower.nupkg"

$workDir = Join-Path ([IO.Path]::GetTempPath()) ("fedupdate-webview2-" + [Guid]::NewGuid().ToString("N"))
# Expand-Archive keys off the file extension, so the package is saved as .zip.
$packageFile = Join-Path $workDir "webview2.zip"
$extractDir = Join-Path $workDir "extracted"

try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Write-Host "[INFO] Downloading Microsoft.Web.WebView2 $Version..." -ForegroundColor Cyan
    $progressPreferenceOriginal = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"   # Restores throughput lost to the progress bar
    try {
        Invoke-WebRequest -Uri $packageUrl -OutFile $packageFile -UseBasicParsing
    } finally {
        $ProgressPreference = $progressPreferenceOriginal
    }

    Expand-Archive -Path $packageFile -DestinationPath $extractDir -Force

    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

    # net462 targets the .NET Framework build produced by build.ps1.
    $managedSource = Join-Path $extractDir "lib\net462"
    if (-not (Test-Path $managedSource)) {
        throw "Expected managed assemblies at lib/net462 were not found in the package."
    }

    foreach ($dll in $managedAssemblies) {
        $source = Join-Path $managedSource $dll
        if (-not (Test-Path $source)) { throw "Missing $dll in the downloaded package." }
        Copy-Item $source $binDir -Force
        Write-Host "  [OK] $dll" -ForegroundColor Green
    }

    $loaderSource = Join-Path $extractDir "runtimes\win-x64\native\$nativeLoader"
    if (-not (Test-Path $loaderSource)) {
        throw "Missing the x64 $nativeLoader in the downloaded package."
    }
    Copy-Item $loaderSource $binDir -Force
    Write-Host "  [OK] $nativeLoader (x64)" -ForegroundColor Green

    Write-Host "[OK] WebView2 $Version restored to gui/bin." -ForegroundColor Green
} catch {
    Write-Error "WebView2 restore failed: $_"
    exit 1
} finally {
    if (Test-Path $workDir) {
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
