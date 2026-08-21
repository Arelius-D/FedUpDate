# ==============================================================================
# FedUpDate Microsoft Store Sync Engine
# Triggers Enterprise MDM Modern App Management background scan & Store updates
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\WingetEngine.ps1"

function Sync-FedStoreApps {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf
    )

    Write-FedLog "Triggering Microsoft Store background update scan engine..." -Level "INFO" -Component "StoreSync"

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would invoke MDM_EnterpriseModernAppManagement_AppManagement01.UpdateScanMethod via CIM/WMI" -Level "WHATIF" -Component "StoreSync"
        return [PSCustomObject]@{
            Success = $true
            Method  = "MDM_CIM_Simulated"
            Message = "WhatIf simulation completed."
        }
    }

    $cimSuccess = $false
    $cimError = $null

    try {
        $mdmInstance = Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" -ErrorAction Stop
        if ($null -ne $mdmInstance) {
            $invokeResult = Invoke-CimMethod -InputObject $mdmInstance -MethodName "UpdateScanMethod" -ErrorAction Stop
            $cimSuccess = $true
            Write-FedLog "Successfully invoked Microsoft Store background scan via CIM MDM bridge." -Level "SUCCESS" -Component "StoreSync"
            return [PSCustomObject]@{
                Success = $true
                Method  = "MDM_CIM"
                Result  = $invokeResult
            }
        }
    } catch {
        $cimError = $_.ToString()
        Write-FedLog "Direct CIM MDM bridge returned: $cimError. Attempting WinGet store source refresh..." -Level "WARN" -Component "StoreSync"
    }

    # Secondary Store Queue Sync via WinGet msstore source
    try {
        $wingetPath = Get-FedWingetPath
        if ($wingetPath) {
            Write-FedLog "Triggering MS Store source refresh via WinGet..." -Level "INFO" -Component "StoreSync"
            Start-Process -FilePath $wingetPath -ArgumentList "source update msstore --disable-interactivity" -Wait -NoNewWindow -ErrorAction SilentlyContinue
            return [PSCustomObject]@{
                Success = $true
                Method  = "WinGet_MSStore"
            }
        }
    } catch { }

    return [PSCustomObject]@{
        Success = $cimSuccess
        Method  = "Failed"
        Error   = $cimError
    }
}

function Get-FedStoreStatus {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Deep = $false
    )

    # Check if Microsoft Store is installed and active
    $storePkg = Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue
    $isInstalled = ($null -ne $storePkg)
    $version = if ($storePkg) { $storePkg.Version } else { "N/A" }

    # Query pending Store updates via WinGet msstore source only if Deep scan requested
    $storeUpdates = [System.Collections.Generic.List[PSObject]]::new()
    if ($Deep) {
        try {
            $wingetPath = Get-FedWingetPath
            if ($wingetPath) {
                $procInfo = New-Object System.Diagnostics.ProcessStartInfo
                $procInfo.FileName = $wingetPath
                $procInfo.Arguments = "upgrade --source msstore --include-unknown --accept-source-agreements --disable-interactivity"
                $procInfo.RedirectStandardOutput = $true
                $procInfo.RedirectStandardError = $true
                $procInfo.UseShellExecute = $false
                $procInfo.CreateNoWindow = $true
                $procInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8

                $process = [System.Diagnostics.Process]::Start($procInfo)
                if ($process.WaitForExit(3500)) {
                    $output = $process.StandardOutput.ReadToEnd()
                    $lines = $output -split "`r?`n"
                    $headerFound = $false
                    $colPositions = @{}

                    foreach ($line in $lines) {
                        $trimmed = $line.Trim()
                        if (-not $trimmed) { continue }
                        if ($trimmed -match "^Name\s+Id\s+Version\s+Available") {
                            $headerFound = $true
                            $colPositions["Name"] = 0
                            $colPositions["Id"] = $line.IndexOf("Id")
                            $colPositions["Version"] = $line.IndexOf("Version")
                            $colPositions["Available"] = $line.IndexOf("Available")
                            continue
                        }
                        if ($headerFound -and ($trimmed -match "^[-=\s]+$" -or $trimmed.StartsWith("---"))) { continue }
                        if ($headerFound -and $trimmed.Length -gt 0) {
                            if ($trimmed -match "^\d+\s+upgrades? available" -or $trimmed -match "^The following packages") { break }
                            try {
                                $idStart = $colPositions["Id"]
                                $verStart = $colPositions["Version"]
                                $availStart = $colPositions["Available"]
                                if ($line.Length -gt $availStart) {
                                    $name = $line.Substring(0, [math]::Min($idStart, $line.Length)).Trim()
                                    $id = $line.Substring($idStart, [math]::Min($verStart - $idStart, $line.Length - $idStart)).Trim()
                                    $ver = $line.Substring($verStart, [math]::Min($availStart - $verStart, $line.Length - $verStart)).Trim()
                                    $avail = $line.Substring($availStart).Trim()
                                    if ($id -and $avail) {
                                        $storeUpdates.Add([PSCustomObject]@{
                                            Name             = $name
                                            Id               = $id
                                            CurrentVersion   = $ver
                                            AvailableVersion = $avail
                                            Source           = "msstore"
                                        })
                                    }
                                }
                            } catch {}
                        }
                    }
                } else {
                    try { $process.Kill() } catch {}
                }
            }
        } catch {}
    }

    return [PSCustomObject]@{
        IsInstalled = $isInstalled
        Version     = $version
        PackageName = if ($storePkg) { $storePkg.PackageFullName } else { $null }
        UpdateCount = $storeUpdates.Count
        Updates     = @($storeUpdates)
    }
}

Export-ModuleMember -Function Sync-FedStoreApps, Get-FedStoreStatus -ErrorAction SilentlyContinue
