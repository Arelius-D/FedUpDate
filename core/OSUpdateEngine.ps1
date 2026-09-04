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

    # Output is captured rather than inherited. With -NoNewWindow the tool
    # writes straight to the console, so its banner and version list appeared
    # unformatted in the middle of the run, outside the log and outside the file.
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process -FilePath $mpPath -ArgumentList "-SignatureUpdate -MMPC" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        # The tool says whether anything was actually needed, which is worth
        # keeping. The version banner around it is not.
        $summary = $null
        foreach ($line in @(Get-Content $outFile -ErrorAction SilentlyContinue)) {
            if ($line -match 'Signature update (finished|failed)') { $summary = $line.Trim() }
        }

        if ($process.ExitCode -eq 0) {
            if ($summary) {
                Write-FedLog "Microsoft Defender signatures: $summary" -Level "SUCCESS" -Component "Defender"
            } else {
                Write-FedLog "Microsoft Defender signatures updated successfully." -Level "SUCCESS" -Component "Defender"
            }
            return $true
        } else {
            Write-FedLog "MpCmdRun exited with code $($process.ExitCode)." -Level "WARN" -Component "Defender"
            return $false
        }
    } catch {
        Write-FedLog "Failed to trigger Defender update: $_" -Level "ERROR" -Component "Defender"
        return $false
    } finally {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
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
                # Recorded, not merely warned about. The caller has to be able to
                # tell "nothing is pending" apart from "nobody was allowed to
                # look", because otherwise both are the same empty list.
                $script:FedOSScanBlocked = $true
                $script:FedOSScanReason = "The Windows Update service is disabled by the anti-tamper shield, and checking for updates needs elevation."
                Write-FedLog "Windows Update service is disabled and this session is not elevated, so no scan could run." -Level "WARN" -Component "OSUpdate"
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

function Get-FedOSScanCacheFile {
    return Join-Path (Get-FedDataDirectory) "os_scan_cache.json"
}

function Save-FedOSScanCache {
    <#
    .SYNOPSIS
        Records the result of a scan that was actually allowed to run.
    .DESCRIPTION
        The session able to run a scan is not always the session that needs the
        answer. The elevated check runs in its own process and exits, so unless
        its result is written down it dies with that process and the window that
        asked for it is no better informed than before it asked.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [array]$Updates
    )

    try {
        $payload = [PSCustomObject]@{
            CheckedAt = (Get-Date).ToString("o")
            Count     = [int]@($Updates).Count
            Updates   = @($Updates)
        }
        $payload | ConvertTo-Json -Depth 6 | Set-Content -Path (Get-FedOSScanCacheFile) -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-FedLog "Could not record the Windows Update scan result: $_" -Level "WARN" -Component "OSUpdate"
    }
}

function Get-FedOSScanCache {
    <#
    .SYNOPSIS
        The last scan that ran, or nothing if none ever has.
    #>
    [CmdletBinding()]
    param()

    $file = Get-FedOSScanCacheFile
    if (-not (Test-Path $file)) { return $null }

    try {
        $raw = Get-Content -Path $file -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data -or $null -eq $data.CheckedAt) { return $null }
        return $data
    } catch {
        return $null
    }
}

function Get-FedOSInstallResultFile {
    return Join-Path (Get-FedDataDirectory) "os_install_result.json"
}

function Save-FedOSInstallResult {
    <#
    .SYNOPSIS
        Records what an installation actually did.
    .DESCRIPTION
        Installing needs elevation, so an unelevated run hands the work to a
        second process. That process exits, and an exit code says only that it
        ran, not what it achieved. Without this the caller has to guess, and
        guessing reported every update as installed by a run that installed
        none of them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )

    try {
        $Result | ConvertTo-Json -Depth 6 | Set-Content -Path (Get-FedOSInstallResultFile) -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-FedLog "Could not record the installation result: $_" -Level "WARN" -Component "OSUpdate"
    }
}

function Get-FedOSInstallResult {
    <#
    .SYNOPSIS
        What the last recorded installation did, or nothing if none has run.
    #>
    [CmdletBinding()]
    param()

    $file = Get-FedOSInstallResultFile
    if (-not (Test-Path $file)) { return $null }
    try {
        $raw = Get-Content -Path $file -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Clear-FedOSInstallResult {
    <#
    .SYNOPSIS
        Discards the recorded installation so a stale one is never read as new.
    #>
    [CmdletBinding()]
    param()

    $file = Get-FedOSInstallResultFile
    if (Test-Path $file) { Remove-Item -Path $file -Force -ErrorAction SilentlyContinue }
}

function Clear-FedOSScanCache {
    <#
    .SYNOPSIS
        Discards the recorded scan once it can no longer be true.
    #>
    [CmdletBinding()]
    param()

    $file = Get-FedOSScanCacheFile
    if (Test-Path $file) { Remove-Item -Path $file -Force -ErrorAction SilentlyContinue }
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
    $script:FedOSScanBlocked = $false
    $script:FedOSScanReason = $null
    $script:FedOSScanCached = $false
    $script:FedOSScanCheckedAt = $null
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

        if ($script:FedOSScanBlocked) {
            Write-FedLog "Windows updates were not checked. $($script:FedOSScanReason)" -Level "WARN" -Component "OSUpdate"
        } else {
            Write-FedLog "Found $($results.Count) pending Windows Update(s)." -Level "SUCCESS" -Component "OSUpdate"
        }
    } catch {
        Write-FedLog "Failed to query Windows Update COM API: $_" -Level "WARN" -Component "OSUpdate"
    }

    if ($script:FedOSScanBlocked) {
        # Refused here does not mean unknown everywhere. An elevated check may
        # already have answered this, and that answer is better than reporting
        # nothing at all, so long as it is reported as what it is and dated.
        $cached = Get-FedOSScanCache
        if ($null -ne $cached) {
            foreach ($up in @($cached.Updates)) { $results.Add($up) }
            $script:FedOSScanCached = $true
            $script:FedOSScanCheckedAt = [string]$cached.CheckedAt
            Write-FedLog "Reporting the last elevated check, taken $($cached.CheckedAt), because this session may not run one." -Level "INFO" -Component "OSUpdate"
        }
    } else {
        Save-FedOSScanCache -Updates @($results)
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

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $scanState = Get-FedOSScanState

    if ($UpdatesToInstall.Count -eq 0) {
        # An empty list means one of two things, and they must not be confused:
        # nothing is pending, or nobody was allowed to look. With the shield on
        # an unelevated scan is refused, and treating that refusal as "nothing
        # pending" meant an update run never installed a Windows update and
        # still reported itself complete. When the scan was refused, the
        # decision is handed to an elevated run below, which can both look and
        # install in one go.
        if (-not $scanState.Blocked -or $isAdmin) {
            Write-FedLog "No pending Windows OS updates to install." -Level "INFO" -Component "OSUpdate"
            return [PSCustomObject]@{
                SuccessCount   = 0
                FailCount      = 0
                RebootRequired = $false
            }
        }

        if ($WhatIf) {
            Write-FedLog "[WHATIF] Windows updates could not be checked without elevation, so none can be listed. A real run would ask for it." -Level "WHATIF" -Component "OSUpdate"
            return [PSCustomObject]@{
                SuccessCount   = 0
                FailCount      = 0
                RebootRequired = $false
                NotChecked     = $true
            }
        }

        Write-FedLog "Windows updates could not be checked without elevation. Asking for it, so they can be checked and installed together." -Level "INFO" -Component "OSUpdate"
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
    if (-not $isAdmin) {
        try {
            $scriptRoot = Split-Path -Parent $PSScriptRoot
            $cliScript = Join-Path $scriptRoot "fedupdate.ps1"
            # A stale record from an earlier run must never be read as this one.
            Clear-FedOSInstallResult
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" update -OS" -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
            if ($null -ne $p -and $p.ExitCode -eq 0) {
                # An exit code says the process ran, not what it achieved. This
                # used to report every requested update as installed on the
                # strength of a zero exit, which is how a run that installed
                # nothing was reported as a complete success.
                $childResult = Get-FedOSInstallResult
                $rebootState = Get-FedRebootState

                if ($null -eq $childResult) {
                    Write-FedLog "The elevated run finished without recording what it did, so nothing can be reported as installed." -Level "WARN" -Component "OSUpdate"
                    return [PSCustomObject]@{
                        SuccessCount   = 0
                        FailCount      = $UpdatesToInstall.Count
                        RebootRequired = [bool]$rebootState.IsRebootRequired
                        Error          = "The elevated run recorded no result"
                    }
                }

                $installed = [int]$childResult.SuccessCount
                $failed = [int]$childResult.FailCount
                if ($failed -gt 0 -or $installed -eq 0) {
                    Write-FedLog "The elevated run installed $installed update(s) and did not install $failed. $($childResult.Error)" -Level "WARN" -Component "OSUpdate"
                } else {
                    Write-FedLog "Elevated Windows Update installation completed. Installed $installed update(s)." -Level "SUCCESS" -Component "OSUpdate"
                }

                return [PSCustomObject]@{
                    SuccessCount   = $installed
                    FailCount      = $failed
                    RebootRequired = [bool]$rebootState.IsRebootRequired
                    Error          = $childResult.Error
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
            # Declining is an answer. It is reported as what it is, not as an
            # error and not as "nothing pending", because in the refused-scan
            # case nothing was ever looked at.
            Write-FedLog "Elevation was declined, so Windows updates were neither checked nor installed. Nothing was changed." -Level "WARN" -Component "OSUpdate"
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
            param([string[]]$TargetIds)
            try {
                $session = New-Object -ComObject Microsoft.Update.Session
                $searcher = $session.CreateUpdateSearcher()
                # The same search the scan ran. Both settings used to be left at
                # their defaults here, which asks Windows a different question:
                # the scan reads the local catalogue and this went to the network.
                # The two then disagreed about what was pending, so the list a
                # person was looking at was not the list being installed.
                $searcher.ServerSelection = 0
                $searcher.Online = $false
                $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")

                $collection = New-Object -ComObject Microsoft.Update.UpdateColl
                $missing = @()
                $seen = @()
                if ($null -ne $searchResult -and $null -ne $searchResult.Updates) {
                    foreach ($update in $searchResult.Updates) {
                        $id = $update.Identity.UpdateID
                        $seen += $id
                        if ($TargetIds.Count -gt 0 -and $TargetIds -notcontains $id) { continue }
                        # An unaccepted licence stops that update downloading, and
                        # driver updates are the ones that usually carry one.
                        if (-not $update.EulaAccepted) {
                            try { $update.AcceptEula() } catch { }
                        }
                        $collection.Add($update) | Out-Null
                    }
                }
                foreach ($want in $TargetIds) { if ($seen -notcontains $want) { $missing += $want } }

                if ($collection.Count -eq 0) {
                    return [PSCustomObject]@{ Stage = "search"; Count = 0; Requested = $TargetIds.Count; Missing = $missing; RebootRequired = $false }
                }

                $downloader = $session.CreateUpdateDownloader()
                $downloader.Updates = $collection
                $downloadResult = $downloader.Download()

                $installer = $session.CreateUpdateInstaller()
                $installer.Updates = $collection
                $installer.ForceQuiet = $true
                $installResult = $installer.Install()

                # How many were attempted is not how many were installed. Each
                # update carries its own outcome and only these two codes mean it
                # went on. Counting the collection reported every attempt as a
                # success, including the ones Windows refused.
                $succeeded = 0
                $failed = 0
                $detail = @()
                for ($i = 0; $i -lt $collection.Count; $i++) {
                    $code = 4
                    try { $code = $installResult.GetUpdateResult($i).ResultCode } catch { $code = 4 }
                    if ($code -eq 2 -or $code -eq 3) { $succeeded++ } else { $failed++ }
                    $item = $collection.Item($i)
                    $cats = @($item.Categories | ForEach-Object { $_.Name })
                    $detail += [PSCustomObject]@{
                        Title      = $item.Title
                        IsDriver   = ($cats -contains "Drivers")
                        ResultCode = $code
                    }
                }

                return [PSCustomObject]@{
                    Stage          = "installed"
                    Count          = $succeeded
                    Attempted      = $collection.Count
                    Failed         = $failed
                    Detail         = $detail
                    Missing        = $missing
                    RebootRequired = $installResult.RebootRequired
                    ResultCode     = $installResult.ResultCode
                    DownloadCode   = $downloadResult.ResultCode
                }
            } catch {
                return [PSCustomObject]@{ Stage = "error"; Error = $_.ToString() }
            }
        } -ArgumentList (, [string[]]@($UpdatesToInstall | ForEach-Object { [string]$_.Id } | Where-Object { $_ }))

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
            # Being asked to install updates and finding none of them to install
            # is a failure. It was reported as a completed run, so the updates
            # stayed pending while the run said it had dealt with them.
            $requested = [int]$outcome.Requested
            Write-FedLog "Asked to install $requested Windows update(s), but the Update Agent offered none of them back. Nothing was installed." -Level "ERROR" -Component "OSUpdate"
            $failedResult = [PSCustomObject]@{
                SuccessCount   = 0
                FailCount      = $requested
                RebootRequired = $false
                Error          = "The Update Agent returned none of the $requested requested update(s)"
            }
            Save-FedOSInstallResult -Result $failedResult
            return $failedResult
        }

        foreach ($d in @($outcome.Detail)) {
            if ($d.ResultCode -eq 2 -or $d.ResultCode -eq 3) {
                Write-FedLog "Installed: $($d.Title)" -Level "SUCCESS" -Component "OSUpdate"
            } else {
                $kind = if ($d.IsDriver) { "driver update" } else { "update" }
                Write-FedLog "Not installed ($kind, Windows result code $($d.ResultCode)): $($d.Title)" -Level "WARN" -Component "OSUpdate"
            }
        }
        foreach ($m in @($outcome.Missing)) {
            Write-FedLog "Requested update was not offered back by the Update Agent, so it could not be installed: $m" -Level "WARN" -Component "OSUpdate"
        }

        $level = if ([int]$outcome.Failed -gt 0 -or @($outcome.Missing).Count -gt 0) { "WARN" } else { "SUCCESS" }
        Write-FedLog "Windows Update installation finished. Installed $($outcome.Count) of $($outcome.Attempted) attempted, RebootRequired: $($outcome.RebootRequired), ResultCode: $($outcome.ResultCode)" -Level $level -Component "OSUpdate"
        # What was pending before the install cannot still be pending after it.
        Clear-FedOSScanCache
        $finalResult = [PSCustomObject]@{
            SuccessCount   = $outcome.Count
            FailCount      = ([int]$outcome.Failed + @($outcome.Missing).Count)
            RebootRequired = $outcome.RebootRequired
            ResultCode     = $outcome.ResultCode
        }
        # Written down so an unelevated parent waiting on this process can read
        # what actually happened instead of inferring it from an exit code.
        Save-FedOSInstallResult -Result $finalResult
        return $finalResult
    }
}

Export-ModuleMember -Function Get-FedDefenderStatus, Update-FedDefenderDefinitions, Get-FedOSUpdates, Install-FedOSUpdates -ErrorAction SilentlyContinue

function Get-FedOSScanState {
    <#
    .SYNOPSIS
        Whether the last Windows Update scan was able to run at all.
    .DESCRIPTION
        A scan that was refused and a scan that found nothing both produce an
        empty list. This says which of the two happened, so an interface can
        offer the way forward instead of reporting a zero it never measured.
    #>
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        Blocked   = [bool]$script:FedOSScanBlocked
        Reason    = $script:FedOSScanReason
        CanRetry  = [bool]$script:FedOSScanBlocked
        Cached    = [bool]$script:FedOSScanCached
        CheckedAt = $script:FedOSScanCheckedAt
    }
}

function Invoke-FedElevatedOSScan {
    <#
    .SYNOPSIS
        Re-runs the Windows Update scan once, with elevation.
    .DESCRIPTION
        The shield disables the update service, so a scan needs elevation to
        borrow it back. The borrow already restores the shield in a finally
        block, so the guard is on again by the time this returns whether the
        scan succeeded, failed or was cancelled.

        Declining the prompt is an answer: nothing is changed and the caller is
        told the scan did not run.
    #>
    [CmdletBinding()]
    param()

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        return @(Get-FedOSUpdates)
    }

    try {
        $scriptRoot = Split-Path -Parent $PSScriptRoot
        $cliScript = Join-Path $scriptRoot "fedupdate.ps1"

        Write-FedLog "Requesting elevation to check for Windows updates. The shield is restored afterwards." -Level "INFO" -Component "OSUpdate"
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" scan" -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop

        if ($null -ne $p -and $p.ExitCode -eq 0) {
            Write-FedLog "Elevated Windows Update scan finished." -Level "SUCCESS" -Component "OSUpdate"
            return $true
        }

        Write-FedLog "The elevated scan did not complete." -Level "WARN" -Component "OSUpdate"
        return $false
    } catch {
        Write-FedLog "Elevation was declined, so Windows updates were not checked. The shield is untouched." -Level "WARN" -Component "OSUpdate"
        return $false
    }
}
