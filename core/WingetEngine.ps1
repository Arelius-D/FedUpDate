# ==============================================================================
# FedUpDate WinGet Package Engine
# Structured WinGet package detection, diffing, filtering, and real-time updating
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"

function Get-FedWingetPath {
    $wingetCmd = Get-Command "winget" -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        return $wingetCmd.Source
    }
    $localAppPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $localAppPath) {
        return $localAppPath
    }
    $appxPaths = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue
    if ($appxPaths) {
        return $appxPaths[0].FullName
    }
    return "winget.exe"
}

function Get-FedWingetUpdates {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeExcluded
    )

    $wingetPath = Get-FedWingetPath
    if (-not $wingetPath) {
        Write-FedLog "WinGet executable not found on system." -Level "WARN" -Component "WinGet"
        return @()
    }

    Write-FedLog "Scanning for outdated WinGet packages..." -Level "INFO" -Component "WinGet"
    $config = Get-FedConfig
    $exclusions = @($config.exclusions.wingetPackageIds)

    $results = [System.Collections.Generic.List[PSObject]]::new()

    try {
        $procInfo = New-Object System.Diagnostics.ProcessStartInfo
        $procInfo.FileName = $wingetPath
        $procInfo.Arguments = "upgrade --include-unknown --accept-source-agreements --disable-interactivity"
        $procInfo.RedirectStandardOutput = $true
        $procInfo.RedirectStandardError = $false
        $procInfo.UseShellExecute = $false
        $procInfo.CreateNoWindow = $true
        $procInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8

        $process = [System.Diagnostics.Process]::Start($procInfo)
        $output = $process.StandardOutput.ReadToEnd()
        [void]$process.WaitForExit(8000)
        $lines = $output -split "`r?`n"
        $headerFound = $false
        $colPositions = @{}

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if (-not $trimmed) { continue }

            # Match header line containing Name, Id, Version, Available
            if ($trimmed -match "^Name\s+Id\s+Version\s+Available") {
                $headerFound = $true
                
                # Compute column start positions
                $colPositions["Name"] = 0
                $colPositions["Id"] = $line.IndexOf("Id")
                $colPositions["Version"] = $line.IndexOf("Version")
                $colPositions["Available"] = $line.IndexOf("Available")
                $colPositions["Source"] = if ($line.Contains("Source")) { $line.IndexOf("Source") } else { -1 }
                continue
            }

            # Skip separator line (e.g. -------------------)
            if ($headerFound -and ($trimmed -match "^[-=\s]+$" -or $trimmed.StartsWith("---"))) {
                continue
            }

            # Parse package rows
            if ($headerFound -and $trimmed.Length -gt 0) {
                # Stop if summary line reached (e.g. "X upgrades available.")
                if ($trimmed -match "^\d+\s+upgrades? available" -or $trimmed -match "^The following packages") {
                    break
                }

                try {
                    $idStart = $colPositions["Id"]
                    $verStart = $colPositions["Version"]
                    $availStart = $colPositions["Available"]
                    $srcStart = $colPositions["Source"]

                    if ($line.Length -gt $availStart) {
                        $name = $line.Substring(0, [math]::Min($idStart, $line.Length)).Trim()
                        $id = $line.Substring($idStart, [math]::Min($verStart - $idStart, $line.Length - $idStart)).Trim()
                        $ver = $line.Substring($verStart, [math]::Min($availStart - $verStart, $line.Length - $verStart)).Trim()
                        
                        $avail = ""
                        $source = "winget"

                        if ($srcStart -gt 0 -and $line.Length -gt $srcStart) {
                            $avail = $line.Substring($availStart, $srcStart - $availStart).Trim()
                            $source = $line.Substring($srcStart).Trim()
                        } else {
                            $avail = $line.Substring($availStart).Trim()
                        }

                        if ($name.Length -gt 0 -and $id.Length -gt 0 -and $avail.Length -gt 0 -and $id -ne "Id" -and $avail -ne "<" -and $avail -ne ">") {
                            $isExcluded = ($exclusions -contains $id) -or ($exclusions -contains $name)
                            if (-not $isExcluded -or $IncludeExcluded) {
                                $results.Add([PSCustomObject]@{
                                    Name             = $name
                                    Id               = $id
                                    CurrentVersion   = $ver
                                    AvailableVersion = $avail
                                    Source           = $source
                                    IsExcluded       = $isExcluded
                                })
                            }
                        }
                    }
                } catch {
                    # Skip malformed line
                }
            }
        }

        Write-FedLog "Found $($results.Count) outdated WinGet package(s)." -Level "SUCCESS" -Component "WinGet"
    } catch {
        Write-FedLog "Error querying WinGet: $_" -Level "ERROR" -Component "WinGet"
    }

    return @($results)
}

function Update-FedWingetPackages {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$PackageIds,

        [Parameter()]
        [switch]$All,

        [Parameter()]
        [switch]$WhatIf
    )

    $wingetPath = Get-FedWingetPath
    if (-not $wingetPath) {
        Write-FedLog "WinGet not found." -Level "ERROR" -Component "WinGet"
        return $false
    }

    $config = Get-FedConfig
    $exclusions = @($config.exclusions.wingetPackageIds)

    if ($WhatIf) {
        if ($PackageIds -and $PackageIds.Count -gt 0) {
            Write-FedLog "[WHATIF] Would upgrade $($PackageIds.Count) WinGet package(s): $($PackageIds -join ', ')" -Level "WHATIF" -Component "WinGet"
        } else {
            Write-FedLog "[WHATIF] Would execute: winget upgrade --all --accept-package-agreements --accept-source-agreements --include-unknown" -Level "WHATIF" -Component "WinGet"
        }
        return $true
    }

    if ($PackageIds -and $PackageIds.Count -gt 0) {
        $success = 0
        $failed = 0
        foreach ($pkgId in $PackageIds) {
            if ($exclusions -contains $pkgId) {
                Write-FedLog "Skipping excluded package: $pkgId" -Level "INFO" -Component "WinGet"
                continue
            }

            Write-FedLog "Upgrading package: $pkgId..." -Level "INFO" -Component "WinGet"
            $args = "upgrade --id `"$pkgId`" --exact --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"
            
            $exitCode = Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $args
            if ($exitCode -eq -1978335090) {
                Write-FedLog "Installer technology changed for $pkgId. Automatically replacing legacy install with newer version..." -Level "INFO" -Component "WinGet"
                $uninstArgs = "uninstall --id `"$pkgId`" --force --disable-interactivity"
                Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $uninstArgs | Out-Null
                $installArgs = "install --id `"$pkgId`" --exact --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"
                $exitCode = Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $installArgs
            } elseif ($exitCode -ne 0 -and $exitCode -ne 2316632065) {
                Write-FedLog "Standard upgrade returned ($exitCode). Retrying with force installation..." -Level "INFO" -Component "WinGet"
                $argsForce = "install --id `"$pkgId`" --force --exact --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"
                $exitCode = Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $argsForce
            }

            if ($exitCode -eq 0 -or $exitCode -eq 2316632065) {
                Write-FedLog "Successfully upgraded package: $pkgId" -Level "SUCCESS" -Component "WinGet"
                $success++
            } else {
                Write-FedLog "Failed or cancelled upgrade for: $pkgId (ExitCode: $exitCode)" -Level "WARN" -Component "WinGet"
                $failed++
            }
        }
        return [PSCustomObject]@{ Success = $success; Failed = $failed }
    } else {
        # Upgrade All
        Write-FedLog "Executing full WinGet system upgrade..." -Level "INFO" -Component "WinGet"
        $args = "upgrade --all --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"
        $exitCode = Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $args
        
        Write-FedLog "WinGet batch upgrade completed (ExitCode: $exitCode)." -Level "SUCCESS" -Component "WinGet"
        return ($exitCode -eq 0)
    }
}

function Invoke-FedWingetProcess {
    param([string]$wingetPath, [string]$arguments)

    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName = $wingetPath
    $procInfo.Arguments = $arguments
    $procInfo.RedirectStandardOutput = $true
    $procInfo.RedirectStandardError = $false
    $procInfo.UseShellExecute = $false
    $procInfo.CreateNoWindow = $true
    $procInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8

    $process = [System.Diagnostics.Process]::Start($procInfo)
    while (-not $process.StandardOutput.EndOfStream) {
        $line = $process.StandardOutput.ReadLine()
        if ($line -and $line.Trim()) {
            Write-FedLog $line.Trim() -Level "INFO" -Component "WinGet"
        }
    }
    $process.WaitForExit()
    return $process.ExitCode
}

Export-ModuleMember -Function Get-FedWingetPath, Get-FedWingetUpdates, Update-FedWingetPackages, Invoke-FedWingetProcess -ErrorAction SilentlyContinue
