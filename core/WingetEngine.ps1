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
        $inUse = 0
        $detail = @()
        foreach ($pkgId in $PackageIds) {
            if ($exclusions -contains $pkgId) {
                Write-FedLog "Skipping excluded package: $pkgId" -Level "INFO" -Component "WinGet"
                continue
            }

            Write-FedLog "Upgrading package: $pkgId..." -Level "INFO" -Component "WinGet"
            $args = "upgrade --id `"$pkgId`" --exact --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"

            $run = Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $args -PassThruOutput
            $exitCode = $run.ExitCode
            $outcomes = @(Get-FedWingetOutcomes -Lines $run.Lines)
            if ($exitCode -eq -1978335090) {
                Write-FedLog "Installer technology changed for $pkgId. Automatically replacing legacy install with newer version..." -Level "INFO" -Component "WinGet"
                $uninstArgs = "uninstall --id `"$pkgId`" --force --disable-interactivity"
                Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $uninstArgs | Out-Null
                $installArgs = "install --id `"$pkgId`" --exact --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"
                $run = Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $installArgs -PassThruOutput
                $exitCode = $run.ExitCode
                $outcomes = @(Get-FedWingetOutcomes -Lines $run.Lines)
            } elseif ($exitCode -ne 0 -and $exitCode -ne 2316632065 -and -not ($outcomes | Where-Object { $_.Outcome -eq "InUse" })) {
                # Not retried when the application is open. Forcing the install
                # runs the same installer against the same open application,
                # and it stops for the same reason.
                Write-FedLog "Standard upgrade returned ($exitCode). Retrying with force installation..." -Level "INFO" -Component "WinGet"
                $argsForce = "install --id `"$pkgId`" --force --exact --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"
                $run = Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $argsForce -PassThruOutput
                $exitCode = $run.ExitCode
                $outcomes = @(Get-FedWingetOutcomes -Lines $run.Lines)
            }

            $detail += $outcomes
            $held = @($outcomes | Where-Object { $_.Outcome -eq "InUse" })
            if ($held.Count -gt 0) {
                $name = if ($held[0].Name) { $held[0].Name } else { $pkgId }
                Write-FedLog "$name was not upgraded because it is open. Close it and run the upgrade again." -Level "WARN" -Component "WinGet"
                $inUse++
            } elseif ($exitCode -eq 0 -or $exitCode -eq 2316632065) {
                Write-FedLog "Successfully upgraded package: $pkgId" -Level "SUCCESS" -Component "WinGet"
                $success++
            } else {
                Write-FedLog "Failed or cancelled upgrade for: $pkgId (ExitCode: $exitCode)" -Level "WARN" -Component "WinGet"
                $failed++
            }
        }
        return [PSCustomObject]@{ Success = $success; Failed = $failed; InUse = $inUse; Detail = $detail }
    } else {
        # Upgrade All
        Write-FedLog "Executing full WinGet system upgrade..." -Level "INFO" -Component "WinGet"
        $args = "upgrade --all --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"
        $run = Invoke-FedWingetProcess -wingetPath $wingetPath -arguments $args -PassThruOutput
        $exitCode = $run.ExitCode

        # One exit code covers the whole batch and says nothing about which
        # package it refers to. A batch with one refusal in it was logged as
        # completed, at success level, on the strength of having finished.
        # WinGet names each package as it reaches it and says how its install
        # ended, and that is what each package is reported from.
        $outcomes = @(Get-FedWingetOutcomes -Lines $run.Lines)
        $success = 0
        $failed = 0
        $inUse = 0
        foreach ($o in $outcomes) {
            switch ($o.Outcome) {
                "Installed" {
                    $success++
                    Write-FedLog "Upgraded $($o.Name) to $($o.Version)." -Level "SUCCESS" -Component "WinGet"
                }
                "InUse" {
                    $inUse++
                    Write-FedLog "$($o.Name) was not upgraded because it is open. Close it and run the upgrade again." -Level "WARN" -Component "WinGet"
                }
                "Failed" {
                    $failed++
                    Write-FedLog "The installer for $($o.Name) stopped with exit code $($o.InstallerExitCode). Its log: $($o.InstallerLog)" -Level "WARN" -Component "WinGet"
                }
                default {
                    $failed++
                    Write-FedLog "$($o.Name) was reached, but WinGet did not say how its install ended." -Level "WARN" -Component "WinGet"
                }
            }
        }

        if ($outcomes.Count -eq 0) {
            $nothingToDo = [bool](@($run.Lines) -match 'No applicable update|No installed package found|No available upgrade')
            if ($exitCode -eq 0 -or $nothingToDo) {
                Write-FedLog "WinGet found nothing to upgrade." -Level "INFO" -Component "WinGet"
            } else {
                Write-FedLog "WinGet exited with code $exitCode without naming a package." -Level "WARN" -Component "WinGet"
                $failed++
            }
        } else {
            $level = if ($failed -gt 0 -or $inUse -gt 0) { "WARN" } else { "SUCCESS" }
            Write-FedLog "WinGet upgrade finished: $success upgraded, $inUse waiting for an application to be closed, $failed failed (WinGet exit code $exitCode)." -Level $level -Component "WinGet"
        }
        return [PSCustomObject]@{ Success = $success; Failed = $failed; InUse = $inUse; Detail = $outcomes; ExitCode = $exitCode }
    }
}

function Get-FedWingetOutcomes {
    <#
    .SYNOPSIS
        What happened to each package in a WinGet run, read from what it printed.
    .DESCRIPTION
        WinGet hands back one exit code for a whole run. With several packages
        in it, that code says nothing about which of them went on. Its output
        names each package as it reaches it and says how the install ended, so
        that is read instead.

        An installer that stops because the application is open is the
        commonest refusal, and not a failure of anything. WinGet reports it
        only as an exit code, but the installer says why in its own log, which
        WinGet names, and that log is read. The case is reported as what it is,
        with what to do about it.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$Lines
    )

    $outcomes = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($raw in @($Lines)) {
        # Progress is written over itself with carriage returns, so one line
        # read can hold several of WinGet's.
        foreach ($piece in ([string]$raw -split "`r")) {
            $line = $piece.Trim()
            if (-not $line) { continue }
            if ($line -match '^\(\d+/\d+\) Found (.+?) \[(.+?)\] Version (.+)$') {
                $current = [PSCustomObject]@{
                    Name              = $Matches[1].Trim()
                    Id                = $Matches[2].Trim()
                    Version           = $Matches[3].Trim()
                    Outcome           = "Unknown"
                    InstallerExitCode = $null
                    InstallerLog      = $null
                }
                $outcomes.Add($current)
                continue
            }
            if ($null -eq $current) { continue }
            if ($line -match '^Successfully installed') { $current.Outcome = "Installed"; continue }
            if ($line -match 'currently running|Exit the application|close all instances') { $current.Outcome = "InUse"; continue }
            if ($line -match '^Installer failed with exit code: (-?\d+)') {
                $current.InstallerExitCode = [int64]$Matches[1]
                if ($current.Outcome -ne "InUse") { $current.Outcome = "Failed" }
                continue
            }
            if ($line -match '^Installer log is available at: (.+)$') {
                $current.InstallerLog = $Matches[1].Trim()
                if ($current.Outcome -eq "Failed" -and (Test-FedInstallerStoppedForOpenApp -LogPath $current.InstallerLog)) {
                    $current.Outcome = "InUse"
                }
                continue
            }
        }
    }
    return @($outcomes)
}

function Test-FedInstallerStoppedForOpenApp {
    <#
    .SYNOPSIS
        Whether an installer's own log says it stopped because the application was open.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) { return $false }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $false }
    try {
        # Inno Setup, Windows Installer and NSIS each say it in their own words.
        $tail = (@(Get-Content -LiteralPath $LogPath -Tail 200 -ErrorAction Stop) -join " ")
        return [bool]($tail -match 'is currently running|close all instances|should be closed|Files in Use|files in use|is running and must be closed|Please close')
    } catch {
        return $false
    }
}

function Invoke-FedWingetProcess {
    param([string]$wingetPath, [string]$arguments, [switch]$PassThruOutput)

    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName = $wingetPath
    $procInfo.Arguments = $arguments
    $procInfo.RedirectStandardOutput = $true
    $procInfo.RedirectStandardError = $false
    $procInfo.UseShellExecute = $false
    $procInfo.CreateNoWindow = $true
    $procInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8

    $lines = [System.Collections.Generic.List[string]]::new()
    $process = [System.Diagnostics.Process]::Start($procInfo)
    while (-not $process.StandardOutput.EndOfStream) {
        $line = $process.StandardOutput.ReadLine()
        if ($line -and $line.Trim()) {
            $lines.Add($line.Trim())
            Write-FedLog $line.Trim() -Level "INFO" -Component "WinGet"
        }
    }
    $process.WaitForExit()
    # The exit code alone, as before, unless the caller asks for what was
    # printed as well. What WinGet prints is the only per package account of a
    # batch it gives.
    if ($PassThruOutput) {
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Lines = @($lines) }
    }
    return $process.ExitCode
}

Export-ModuleMember -Function Get-FedWingetPath, Get-FedWingetUpdates, Update-FedWingetPackages, Invoke-FedWingetProcess, Get-FedWingetOutcomes, Test-FedInstallerStoppedForOpenApp -ErrorAction SilentlyContinue
