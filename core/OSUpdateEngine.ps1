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
        # Only a disabled service blocks the Update Agent. wuauserv is
        # trigger-started, so a stopped service with a Manual start type is
        # brought up on demand and needs no intervention or elevation.
        if ($originalStartType -eq "Disabled") {
            if (-not $isAdmin) {
                Write-FedLog "Windows Update service is disabled and this session is not elevated, so results may be incomplete." -Level "WARN" -Component "OSUpdate"
            } else {
                Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
                Start-Service -Name $serviceName -ErrorAction Stop
                $borrowed = $true
                Write-FedLog "Temporarily started '$serviceName' for the update operation." -Level "INFO" -Component "OSUpdate"
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

    # Installing through the Update Agent requires elevation. Prompt for it the
    # same way the watchdog does, rather than failing or stalling on a COM call
    # that cannot succeed.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        try {
            $scriptRoot = Split-Path -Parent $PSScriptRoot
            $cliScript = Join-Path $scriptRoot "fedupdate.ps1"
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" update -OS" -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
            if ($null -ne $p -and $p.ExitCode -eq 0) {
                Write-FedLog "Elevated Windows Update installation completed successfully." -Level "SUCCESS" -Component "OSUpdate"
                $rebootState = Get-FedRebootState
                return [PSCustomObject]@{
                    SuccessCount   = $UpdatesToInstall.Count
                    FailCount      = 0
                    RebootRequired = [bool]$rebootState.IsRebootRequired
                }
            }
            Write-FedLog "Elevated Windows Update installation did not complete (exit code $($p.ExitCode))." -Level "WARN" -Component "OSUpdate"
            return [PSCustomObject]@{
                SuccessCount   = 0
                FailCount      = $UpdatesToInstall.Count
                RebootRequired = $false
                Error          = "Elevated run returned exit code $($p.ExitCode)"
            }
        } catch {
            Write-FedLog "Could not elevate for Windows Update installation: $($_.Exception.Message)" -Level "ERROR" -Component "OSUpdate"
            return [PSCustomObject]@{
                SuccessCount   = 0
                FailCount      = $UpdatesToInstall.Count
                RebootRequired = $false
                Error          = "Elevation declined or unavailable"
            }
        }
    }

    Write-FedLog "Preparing download & installation of $($UpdatesToInstall.Count) Windows Updates..." -Level "INFO" -Component "OSUpdate"

    # The whole Update Agent conversation runs inside a job. The searcher call
    # blocks indefinitely when Windows is busy, and running it directly stalled
    # the caller with no output. COM objects cannot cross the job boundary, so
    # the session, search, download and install all live inside it and only a
    # summary comes back.
    #
    # The service borrow wraps the job rather than sitting inside it, so the
    # service stays available for the entire operation.
    return Invoke-FedWithUpdateService -Action {
        $installJob = Start-Job -ScriptBlock {
            try {
                $session = New-Object -ComObject Microsoft.Update.Session
                $searcher = $session.CreateUpdateSearcher()
                $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")

                $collection = New-Object -ComObject Microsoft.Update.UpdateColl
                if ($null -ne $searchResult -and $null -ne $searchResult.Updates) {
                    foreach ($update in $searchResult.Updates) { $collection.Add($update) | Out-Null }
                }

                if ($collection.Count -eq 0) {
                    return [PSCustomObject]@{ Stage = "search"; Count = 0; RebootRequired = $false }
                }

                $downloader = $session.CreateUpdateDownloader()
                $downloader.Updates = $collection
                $downloadResult = $downloader.Download()

                $installer = $session.CreateUpdateInstaller()
                $installer.Updates = $collection
                $installer.ForceQuiet = $true
                $installResult = $installer.Install()

                return [PSCustomObject]@{
                    Stage          = "installed"
                    Count          = $collection.Count
                    RebootRequired = $installResult.RebootRequired
                    ResultCode     = $installResult.ResultCode
                    DownloadCode   = $downloadResult.ResultCode
                }
            } catch {
                return [PSCustomObject]@{ Stage = "error"; Error = $_.ToString() }
            }
        }

        Write-FedLog "Downloading and installing Windows update packages..." -Level "INFO" -Component "OSUpdate"

        if (-not ($installJob | Wait-Job -Timeout 1800)) {
            Stop-Job -Job $installJob -ErrorAction SilentlyContinue
            Remove-Job -Job $installJob -Force -ErrorAction SilentlyContinue
            Write-FedLog "Windows Update operation timed out after 30 minutes." -Level "ERROR" -Component "OSUpdate"
            return [PSCustomObject]@{ SuccessCount = 0; FailCount = $UpdatesToInstall.Count; RebootRequired = $false; Error = "Timed out" }
        }

        $outcome = Receive-Job -Job $installJob
        Remove-Job -Job $installJob -Force -ErrorAction SilentlyContinue

        if ($null -eq $outcome -or $outcome.Stage -eq "error") {
            $message = if ($outcome) { $outcome.Error } else { "No result returned" }
            Write-FedLog "Error during Windows Update install: $message" -Level "ERROR" -Component "OSUpdate"
            return [PSCustomObject]@{ SuccessCount = 0; FailCount = $UpdatesToInstall.Count; RebootRequired = $false; Error = $message }
        }

        if ($outcome.Stage -eq "search") {
            Write-FedLog "No updates found in collection for download." -Level "WARN" -Component "OSUpdate"
            return [PSCustomObject]@{ SuccessCount = 0; FailCount = 0; RebootRequired = $false }
        }

        Write-FedLog "Windows Update installation finished. Installed: $($outcome.Count), RebootRequired: $($outcome.RebootRequired), ResultCode: $($outcome.ResultCode)" -Level "SUCCESS" -Component "OSUpdate"
        return [PSCustomObject]@{
            SuccessCount   = $outcome.Count
            FailCount      = 0
            RebootRequired = $outcome.RebootRequired
            ResultCode     = $outcome.ResultCode
        }
    }
}

Export-ModuleMember -Function Get-FedDefenderStatus, Update-FedDefenderDefinitions, Get-FedOSUpdates, Install-FedOSUpdates -ErrorAction SilentlyContinue
