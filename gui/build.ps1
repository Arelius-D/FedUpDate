<#
.SYNOPSIS
    Compiles the native FedUpDate.UI desktop executable.
.DESCRIPTION
    Convenience wrapper calling gui/bin/build.ps1.
#>

$binBuild = Join-Path $PSScriptRoot "bin\build.ps1"
if (Test-Path $binBuild) {
    & $binBuild
} else {
    Write-Error "Build script not found at $binBuild"
}
