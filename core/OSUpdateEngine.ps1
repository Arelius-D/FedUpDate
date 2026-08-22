# ==============================================================================
# FedUpDate OS & Defender Update Engine
# Native Windows Update COM API (Microsoft.Update.Session) + Defender MpCmdRun
# Zero external binary dependencies, full -WhatIf support
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"

function Get-FedDefenderStatus {
    [CmdletBinding()]
    param()

    try {
        $mpPath = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
        if (Test-Path $mpPath) {
            return [PSCustomObject]@{
                EngineFound = $true
                Path        = $mpPath
            }
        }
    } catch { }
    return $null
}

function Update-FedDefenderDefinitions {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf
    )

    Write-FedLog "Checking and updating Microsoft Defender Antivirus signatures..." -Level "INFO" -Component "Defender"
    $mpPath = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"

    if (-not (Test-Path $mpPath)) {
        Write-FedLog "MpCmdRun.exe not found at standard path." -Level "WARN" -Component "Defender"
        return $false
    }

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would execute: MpCmdRun.exe -SignatureUpdate -MMPC" -Level "WHATIF" -Component "Defender"
        return $true
    }

    try {
        $process = Start-Process -FilePath $mpPath -ArgumentList "-SignatureUpdate -MMPC" -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -eq 0) {
            Write-FedLog "Microsoft Defender signatures updated successfully." -Level "SUCCESS" -Component "Defender"
            return $true
        } else {
            Write-FedLog "MpCmdRun exited with code $($process.ExitCode)." -Level "WARN" -Component "Defender"
            return $false
        }
    } catch {
        Write-FedLog "Failed to trigger Defender update: $_" -Level "ERROR" -Component "Defender"
        return $false
    }
}

function Invoke-FedWithUpdateService {
    <#
    .SYNOPSIS
        Runs a scriptblock with the Windows Update service temporarily available.
    .DESCRIPTION
        The Anti-Tamper Watchdog disables wuauserv on purpose. The Windows Update
        Agent COM API needs that service, so a scan run while it is disabled
        returns nothing and looks identical to "no updates available".

        This borrows the service for the duration of the work and restores the
        original start type and running state afterwards. The restore happens in
        a finally block: if the scan throws, the service must still go back to
        how the watchdog left it, or the shield would be silently switched off.

        Changing a service start type requires elevation. Without it the work
        still runs, and the caller is told the result may be incomplete rather
        than being handed a silent zero.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $serviceName = "wuauserv"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-FedLog "Service '$serviceName' not present; running without it." -Level "WARN" -Component "OSUpdate"
        return & $Action
    }

    $originalStartType = $service.StartType
    $originalStatus = $service.Status
    $borrowed = $false

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    try {
        if ($originalStartType -eq "Disabled" -or $originalStatus -ne "Running") {
            if (-not $isAdmin) {
                Write-FedLog "Windows Update service is $originalStatus/$originalStartType and this session is not elevated. Results may be incomplete; run elevated for a full scan." -Level "WARN" -Component "OSUpdate"
            } else {
                if ($originalStartType -eq "Disabled") {
                    Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
                }
                Start-Service -Name $serviceName -ErrorAction Stop
                $borrowed = $true
                Write-FedLog "Temporarily started '$serviceName' for the update query." -Level "INFO" -Component "OSUpdate"
            }
        }

        return & $Action
    } finally {
        if ($borrowed) {
            try {
                if ($originalStatus -ne "Running") {
                    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                }
                if ($originalStartType -eq "Disabled") {
                    Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
                }
                Write-FedLog "Restored '$serviceName' to $originalStatus/$originalStartType." -Level "INFO" -Component "OSUpdate"
            } catch {
                Write-FedLog "Could not restore '$serviceName' to $originalStartType. Run 'fedupdate watchdog enforce' to reapply the shield." -Level "ERROR" -Component "OSUpdate"
            }
        }
    }
}

function Get-FedOSUpdates {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeDefender = $true,

        [Parameter()]
        [switch]$Online = $false
    )

    Write-FedLog "Scanning for Windows Operating System updates..." -Level "INFO" -Component "OSUpdate"
    $results = [System.Collections.Generic.List[PSObject]]::new()

    try {
        $onlineFlag = [bool]$Online.IsPresent
        $searchJob = Start-Job -ScriptBlock {
            param([bool]$isOnline)
            try {
                $sess = New-Object -ComObject Microsoft.Update.Session
                $srch = $sess.CreateUpdateSearcher()
                $srch.ServerSelection = 0
                $srch.Online = $isOnline
                $sr = $srch.Search("IsInstalled=0 and IsHidden=0")
                $items = @()
                if ($null -ne $sr -and $null -ne $sr.Updates) {
                    foreach ($u in $sr.Updates) {
                        $kb = "KB" + ($u.KBArticleIDs | Select-Object -First 1)
                        if ($kb -eq "KB") {
                            if ($u.Title -match "KB(\d+)") { $kb = "KB" + $matches[1] } else { $kb = "N/A" }
                        }
                        $cats = @($u.Categories | ForEach-Object { $_.Name })
                        $items += [PSCustomObject]@{
                            Id             = $u.Identity.UpdateID
                            Title          = $u.Title
                            KB             = $kb
                            SizeMB         = [math]::Round($u.MaxDownloadSize / 1MB, 2)
                            IsSecurity     = ($cats -contains "Security Updates" -or $cats -contains "Critical Updates")
                            IsDriver       = ($cats -contains "Drivers")
                            IsDefender     = ($u.Title -match "Defender|Antivirus|Security Intelligence")
                            RebootRequired = $u.RebootRequired
                        }
                    }
                }
                return $items
            } catch {
                return @()
            }
        } -ArgumentList $onlineFlag

        # The service stays borrowed until the search has finished and been
        # collected. Restoring it any earlier would pull it out from under the
        # running job, which is what an unelevated scan reporting zero looks like.
        Invoke-FedWithUpdateService -Action {
            if ($searchJob | Wait-Job -Timeout 30) {
                $updates = Receive-Job -Job $searchJob
                if ($updates) {
                    foreach ($up in $updates) {
                        $results.Add($up)
                    }
                }
            } else {
                Write-FedLog "Windows Update search timed out. Returned local state." -Level "WARN" -Component "OSUpdate"
                Stop-Job -Job $searchJob -ErrorAction SilentlyContinue
            }
        } | Out-Null
        Remove-Job -Job $searchJob -Force -ErrorAction SilentlyContinue

        Write-FedLog "Found $($results.Count) pending Windows Update(s)." -Level "SUCCESS" -Component "OSUpdate"
    } catch {
        Write-FedLog "Failed to query Windows Update COM API: $_" -Level "WARN" -Component "OSUpdate"
    }

    return @($results)
}

function Install-FedOSUpdates {
    [CmdletBinding()]
    param(
        [Parameter()]
        [array]$UpdatesToInstall,

        [Parameter()]
        [switch]$UpdateDefender = $true,

        [Parameter()]
        [switch]$WhatIf
    )

    if ($UpdateDefender) {
        Update-FedDefenderDefinitions -WhatIf:$WhatIf
    }

    if ($null -eq $UpdatesToInstall -or $UpdatesToInstall.Count -eq 0) {
        $UpdatesToInstall = Get-FedOSUpdates -IncludeDefender:$false
    }

    if ($UpdatesToInstall.Count -eq 0) {
        Write-FedLog "No pending Windows OS updates to install." -Level "INFO" -Component "OSUpdate"
        return [PSCustomObject]@{
            SuccessCount   = 0
            FailCount      = 0
            RebootRequired = $false
        }
    }

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would download and install $($UpdatesToInstall.Count) Windows Update(s):" -Level "WHATIF" -Component "OSUpdate"
        foreach ($u in $UpdatesToInstall) {
            Write-FedLog "[WHATIF]   - $($u.Title) ($($u.KB)) [$($u.SizeMB) MB]" -Level "WHATIF" -Component "OSUpdate"
        }
        return [PSCustomObject]@{
            SuccessCount   = $UpdatesToInstall.Count
            FailCount      = 0
            RebootRequired = ($UpdatesToInstall | Where-Object { $_.RebootRequired }).Count -gt 0
        }
    }

    Write-FedLog "Preparing download & installation of $($UpdatesToInstall.Count) Windows Updates..." -Level "INFO" -Component "OSUpdate"

    # Downloading and installing both go through the Update Agent, which needs
    # the service the watchdog disables. The borrow covers the whole operation
    # and restores the service afterwards, including on failure.
    return Invoke-FedWithUpdateService -Action {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")

        $downloader = $session.CreateUpdateDownloader()
        $updatesCollection = New-Object -ComObject Microsoft.Update.UpdateColl

        if ($null -ne $searchResult -and $null -ne $searchResult.Updates) {
            foreach ($update in $searchResult.Updates) {
                $updatesCollection.Add($update) | Out-Null
            }
        }

        if ($updatesCollection.Count -eq 0) {
            Write-FedLog "No updates found in collection for download." -Level "WARN" -Component "OSUpdate"
            return $null
        }

        $downloader.Updates = $updatesCollection
        Write-FedLog "Downloading Windows update packages..." -Level "INFO" -Component "OSUpdate"
        $downloadResult = $downloader.Download()

        Write-FedLog "Download finished with ResultCode: $($downloadResult.ResultCode)" -Level "INFO" -Component "OSUpdate"

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $updatesCollection
        $installer.ForceQuiet = $true

        Write-FedLog "Installing Windows updates (background mid-flight reboot suppressed)..." -Level "INFO" -Component "OSUpdate"
        $installResult = $installer.Install()

        $rebootReq = $installResult.RebootRequired
        Write-FedLog "Windows Update installation finished. RebootRequired: $rebootReq, ResultCode: $($installResult.ResultCode)" -Level "SUCCESS" -Component "OSUpdate"

        return [PSCustomObject]@{
            SuccessCount   = $updatesCollection.Count
            FailCount      = 0
            RebootRequired = $rebootReq
            ResultCode     = $installResult.ResultCode
        }
    } catch {
        Write-FedLog "Error during Windows Update install: $_" -Level "ERROR" -Component "OSUpdate"
        return [PSCustomObject]@{
            SuccessCount   = 0
            FailCount      = $UpdatesToInstall.Count
            RebootRequired = $false
            Error          = $_.ToString()
        }
    }
    }
}

Export-ModuleMember -Function Get-FedDefenderStatus, Update-FedDefenderDefinitions, Get-FedOSUpdates, Install-FedOSUpdates -ErrorAction SilentlyContinue
