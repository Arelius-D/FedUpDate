# ==============================================================================
# FedUpDate Master PowerShell Engine Module
# Unified orchestrator bringing all 3 engines, watchdog, rollback, and logger together
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\RollbackEngine.ps1"
. "$PSScriptRoot\OSUpdateEngine.ps1"
. "$PSScriptRoot\WingetEngine.ps1"
. "$PSScriptRoot\StoreEngine.ps1"
. "$PSScriptRoot\RebootEngine.ps1"
. "$PSScriptRoot\AntiTamperWatchdog.ps1"
. "$PSScriptRoot\Scheduler.ps1"
. "$PSScriptRoot\Version.ps1"

function Start-FedScan {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeDefender = $true
    )

    Write-FedLog "=== Starting Unified FedUpDate System Audit ===" -Level "INFO" -Component "Engine"

    # Elevated, this is the process an unelevated window asked to look on its
    # behalf. Lifted and online it can actually see what Windows Update has;
    # unelevated it reads what the last such check wrote down.
    $scanIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $osUpdates = if ($scanIsAdmin) {
        @(Invoke-FedWithShieldLifted -Action { @(Get-FedOSUpdates -IncludeDefender:([bool]$IncludeDefender) -Online) })
    } else {
        @(Get-FedOSUpdates -IncludeDefender:([bool]$IncludeDefender))
    }
    $wingetUpdates = @(Get-FedWingetUpdates)
    $storeStatus = Get-FedStoreStatus
    $rebootState = Get-FedRebootState
    $watchdogAudit = Get-FedWatchdogAudit
    $config = Get-FedConfig

    # Drift on an installation whose guard has never run is not Windows
    # changing anything back. It is the shield not having been applied yet,
    # which is a different thing to tell somebody, with a different remedy.
    $guardState = Get-FedWatchdogState
    $guardEverRan = [bool]($guardState -and ([bool]$guardState.Installed -or -not [string]::IsNullOrWhiteSpace([string]$guardState.LastRun)))

    # Asked once. Two calls could straddle a change and disagree with each other.
    $osScanState = Get-FedOSScanState

    # What an update run installs, kept apart from what Windows offers as
    # optional. The optional ones are listed on their own and never counted as
    # pending.
    $osSplit = Split-FedOSUpdates -Updates $osUpdates
    $osUpdates = @($osSplit.Required)
    $osOptional = @($osSplit.Optional)

    $summary = [PSCustomObject]@{
        Timestamp          = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        OSScanBlocked      = [bool]$osScanState.Blocked
        OSScanReason       = [string]$osScanState.Reason
        OSScanCached       = [bool]$osScanState.Cached
        OSScanCheckedAt    = [string]$osScanState.CheckedAt
        OSUpdateCount      = [int]@($osUpdates).Count
        # Installed already, and offered by Windows until the restart that
        # finishes them. Counted within the total, and named so an interface
        # can say so rather than asking for them to be installed again.
        OSAwaitingRestartCount = [int]@($osUpdates | Where-Object { $_.AwaitingRestart }).Count
        OSUpdates          = @($osUpdates)
        OSOptionalUpdates  = @($osOptional)
        OSOptionalCount    = [int]@($osOptional).Count
        WingetUpdateCount  = [int]@($wingetUpdates).Count
        WingetUpdates      = @($wingetUpdates)
        StoreInstalled     = [bool]$storeStatus.IsInstalled
        StoreVersion       = [string]$storeStatus.Version
        StoreUpdateCount   = [int]$storeStatus.UpdateCount
        StoreUpdates       = @($storeStatus.Updates)
        IsRebootRequired   = [bool]$rebootState.IsRebootRequired
        RebootSeverity     = [string]$rebootState.Severity
        RebootPendingFiles = @($rebootState.PendingFiles)
        RebootSurvivedBoot = [bool]$rebootState.SurvivedLastBoot
        RebootReasons      = @($rebootState.Reasons)
        WatchdogDrifted    = [bool]$watchdogAudit.HasDrifted
        WatchdogNeverApplied = [bool]($config.watchdog.enabled -and $watchdogAudit.HasDrifted -and -not $guardEverRan)
        WatchdogDriftItems = @($watchdogAudit.DriftItems)
        Config             = $config
    }

    # Save scan cache for instant UI hydration on next startup
    try {
        $cacheDir = Join-Path (Split-Path -Parent $PSScriptRoot) "data"
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
        $cacheFile = Join-Path $cacheDir "last_scan.json"
        $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $cacheFile -Encoding UTF8 -Force
    } catch { }

    Write-FedLog "Audit Complete: $(@($osUpdates).Count) OS KBs, $(@($wingetUpdates).Count) WinGet apps, $([int]$storeStatus.UpdateCount) Store apps, Reboot: $($rebootState.Severity), WatchdogDrift: $($watchdogAudit.HasDrifted)" -Level "SUCCESS" -Component "Engine"

    return $summary
}

function Get-FedUpdateRunFile {
    return Join-Path (Get-FedDataDirectory) "update_run.json"
}

function Get-FedActiveUpdateRun {
    <#
    .SYNOPSIS
        The update run in progress, if its process is still alive.
    .DESCRIPTION
        A record left by a process that has gone, or whose number now belongs
        to another program, is no run at all.
    #>
    [CmdletBinding()]
    param()

    $f = Get-FedUpdateRunFile
    if (-not (Test-Path $f)) { return $null }
    try { $r = Get-Content -Path $f -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $r -or -not $r.Pid) { return $null }
    $p = Get-Process -Id ([int]$r.Pid) -ErrorAction SilentlyContinue
    if ($null -eq $p -or $p.ProcessName -ne [string]$r.Process) { return $null }
    return $r
}

function Enter-FedUpdateRun {
    <#
    .SYNOPSIS
        Claims the one update run there may be at a time, or says who has it.
    .DESCRIPTION
        Two runs at once undo each other. Each lifts the shield for Windows
        Update and puts it back when it is done, and the first to finish put
        it back while the second was still installing, so the second lost the
        update service mid-install and its updates failed. A daily schedule
        and a click two minutes before it were enough. One run proceeds, and
        any other is refused and says which run it met.

        The claim is a file moved into place, which succeeds for exactly one of
        two processes claiming at once and is never seen half written. A claim
        left by a process that has gone is taken over. The elevated half of a
        run, started by the run itself, carries the run's ID and is let through.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RunId
    )

    $f = Get-FedUpdateRunFile
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $active = Get-FedActiveUpdateRun
        if ($null -ne $active) {
            if ($RunId -and [string]$active.RunId -eq $RunId) {
                return [PSCustomObject]@{ Entered = $true; Owner = $false; RunId = $RunId; Active = $active }
            }
            return [PSCustomObject]@{ Entered = $false; Owner = $false; RunId = $null; Active = $active }
        }
        if (Test-Path $f) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }

        $claim = [PSCustomObject]@{
            RunId     = [guid]::NewGuid().ToString()
            Pid       = $PID
            Process   = [string](Get-Process -Id $PID).ProcessName
            StartedAt = (Get-Date).ToString("o")
        }
        $tmp = "$f.$PID.tmp"
        try {
            Set-Content -Path $tmp -Value ($claim | ConvertTo-Json -Compress) -Encoding UTF8 -ErrorAction Stop
            [System.IO.File]::Move($tmp, $f)
            return [PSCustomObject]@{ Entered = $true; Owner = $true; RunId = $claim.RunId; Active = $claim }
        } catch {
            # Somebody claimed it between the look and the claim. Look again.
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return [PSCustomObject]@{ Entered = $false; Owner = $false; RunId = $null; Active = (Get-FedActiveUpdateRun) }
}

function Exit-FedUpdateRun {
    <#
    .SYNOPSIS
        Gives up the claim, if this process made it and it is still this one.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Entry
    )

    if ($null -eq $Entry -or -not $Entry.Owner) { return }
    $f = Get-FedUpdateRunFile
    try {
        $r = Get-Content -Path $f -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$r.RunId -eq [string]$Entry.RunId) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Start-FedUpdate {
    <#
    .SYNOPSIS
        Runs an update, as the only one running.
    .DESCRIPTION
        The run itself is Start-FedUpdateCore. This holds the claim around it,
        and refuses when another run already holds one. A simulation touches
        nothing and is not held.
    #>
    [CmdletBinding()]
    param(
        [switch]$OS,
        [switch]$Winget,
        [switch]$Store,
        [switch]$All,
        [string[]]$WingetPackageIds,
        [string[]]$OSUpdateIds,
        [string]$RebootPolicyOverride,
        [switch]$WhatIf,

        # Carried by the elevated half of a run, so the run's own claim lets
        # it through.
        [string]$RunId
    )

    $core = @{}
    foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'RunId') { $core[$k] = $PSBoundParameters[$k] } }

    if ($WhatIf) {
        $r = Start-FedUpdateCore @core
        Add-Member -InputObject $r -NotePropertyName Refused -NotePropertyValue $false -Force
        return $r
    }

    $entry = Enter-FedUpdateRun -RunId $RunId
    if (-not $entry.Entered) {
        $since = try { ([datetime]$entry.Active.StartedAt).ToString("HH:mm") } catch { [string]$entry.Active.StartedAt }
        Write-FedLog "Another update run has been going since $since (process $($entry.Active.Pid)), so this one was not started. Two at once undo each other's work. That run finishes on its own." -Level "WARN" -Component "Engine"
        return [PSCustomObject]@{
            OSResult     = $null
            WingetResult = $null
            StoreResult  = $null
            RebootResult = $null
            Interrupted  = $false
            Refused      = $true
            ActiveSince  = [string]$entry.Active.StartedAt
            ActivePid    = [int]$entry.Active.Pid
        }
    }

    $script:FedUpdateRunId = $entry.RunId
    try {
        $r = Start-FedUpdateCore @core
        Add-Member -InputObject $r -NotePropertyName Refused -NotePropertyValue $false -Force
        return $r
    } finally {
        Exit-FedUpdateRun -Entry $entry
        $script:FedUpdateRunId = $null
    }
}

function Start-FedUpdateCore {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$OS,

        [Parameter()]
        [switch]$Winget,

        [Parameter()]
        [switch]$Store,

        [Parameter()]
        [switch]$All,

        [Parameter()]
        [string[]]$WingetPackageIds,

        # Windows updates to install by ID, and nothing else in the run.
        [Parameter()]
        [string[]]$OSUpdateIds,

        [Parameter()]
        [string]$RebootPolicyOverride,

        [Parameter()]
        [switch]$WhatIf
    )

    $config = Get-FedConfig

    # A Windows update chosen by ID is installed on its own.
    $chosenOS = @($OSUpdateIds | Where-Object { $_ })
    if ($chosenOS.Count -gt 0) { $OS = $true; $All = $false }

    $runOS = $OS -or $All -or ($config.engines.osUpdates -and -not ($OS -or $Winget -or $Store))
    $runWinget = $Winget -or $All -or ($config.engines.wingetApps -and -not ($OS -or $Winget -or $Store))
    $runStore = $Store -or $All -or ($config.engines.storeApps -and -not ($OS -or $Winget -or $Store))

    Write-FedLog "=== Starting Unified Update Run (OS: $runOS, Winget: $runWinget, Store: $runStore, WhatIf: $WhatIf) ===" -Level "INFO" -Component "Engine"

    $results = [PSCustomObject]@{
        OSResult     = $null
        WingetResult = $null
        StoreResult  = $null
        RebootResult = $null
        Interrupted  = $false
    }

    # 1. Windows OS & Defender Updates
    if ($runOS) {
        Write-FedLog "--- [1/3] Operating System & Defender Definitions ---" -Level "INFO" -Component "Engine"
        $results.OSResult = if ($chosenOS.Count -gt 0) {
            # Chosen by ID: that update, without the signature step a full run
            # carries with it.
            Install-FedOSUpdates -UpdateIds $chosenOS -UpdateDefender:$false -WhatIf:$WhatIf
        } else {
            Install-FedOSUpdates -UpdateDefender:$true -WhatIf:$WhatIf
        }

        # The computer slept while this run waited on Windows. Going on to
        # install more on waking, hours after it was asked for, is not what was
        # asked for: an Update All clicked one afternoon went on to upgrade
        # packages the next morning. What is left is left for somebody to start.
        if ($results.OSResult -and $results.OSResult.PSObject.Properties['Slept'] -and $results.OSResult.Slept) {
            Write-FedLog "The computer slept while Windows was installing, so the rest of this run was not started. Run it again to carry on." -Level "WARN" -Component "Engine"
            $runWinget = $false
            $runStore = $false
            $results.Interrupted = $true
        }
    }

    # 2. WinGet Applications
    if ($runWinget) {
        Write-FedLog "--- [2/3] WinGet Package Manager Applications ---" -Level "INFO" -Component "Engine"
        $results.WingetResult = Update-FedWingetPackages -PackageIds $WingetPackageIds -All:($null -eq $WingetPackageIds) -WhatIf:$WhatIf
    }

    # 3. Microsoft Store Background Sync
    if ($runStore) {
        Write-FedLog "--- [3/3] Microsoft Store App Sync Engine ---" -Level "INFO" -Component "Engine"
        $results.StoreResult = Sync-FedStoreApps -WhatIf:$WhatIf
    }

    # 4. Anti-Tamper Enforcement
    #    The Windows Update phase lifts the shield for its duration and restores
    #    it before returning, and says so. Enforcing again here would only raise
    #    a second elevation prompt to re-apply what is already applied.
    if ($config.watchdog.enabled) {
        if ($runOS -and $results.OSResult -and $results.OSResult.ShieldRestored) {
            Write-FedLog "--- Anti-Tamper State already restored by the Windows Update phase ---" -Level "INFO" -Component "Engine"
        } else {
            Write-FedLog "--- Enforcing Anti-Tamper State after updates ---" -Level "INFO" -Component "Engine"
            Enforce-FedWatchdog -WhatIf:$WhatIf | Out-Null
        }
    }

    # 5. Smart Reboot Evaluation
    Write-FedLog "--- Checking Reboot Requirements ---" -Level "INFO" -Component "Engine"
    $results.RebootResult = Invoke-FedRebootPolicy -PolicyOverride $RebootPolicyOverride -WhatIf:$WhatIf

    Write-FedLog "=== Unified Update Run Completed ===" -Level "SUCCESS" -Component "Engine"
    return $results
}

Export-ModuleMember -Function Start-FedScan, Start-FedUpdate, Write-FedLog, Get-FedFriendlyAge, Get-FedLogs, Clear-FedLogs, Get-FedLogDirectory, Get-FedDataDirectory, Get-FedDefaultConfig, Get-FedConfig, Set-FedConfig, Update-FedConfig, Reset-FedConfig, Get-FedRebootState, Get-FedRebootSignalData, Get-FedRebootVerdict, ConvertFrom-FedPendingFileRename, Invoke-FedRebootPolicy, Get-FedWatchdogAudit, Get-FedWatchdogStatus, Format-FedWatchdogStatus, Get-FedWatchdogState, Set-FedWatchdogState, Get-FedManagedState, Test-FedWatchdogSuspended, Suspend-FedWatchdog, Get-FedShieldScanBlockers, Update-FedWatchdogSuspension, Invoke-FedWithShieldLifted, Save-FedInstallBaseline, Enforce-FedWatchdog, Install-FedWatchdogTask, Uninstall-FedWatchdogTask, Test-FedWatchdogTaskExists, Get-FedScheduleTask, Set-FedScheduleTask, Remove-FedScheduleTask, Get-FedWindowsPowerShellPath, Test-FedElevated, Set-FedScheduleConfig, Get-FedActiveUpdateRun, Enter-FedUpdateRun, Exit-FedUpdateRun, Get-FedLiveLiftHolders, Get-FedLedger, Save-FedLedger, New-FedTransaction, Record-FedRegistryChange, Record-FedServiceChange, Record-FedTaskChange, Record-FedFileBackup, Commit-FedTransaction, Restore-FedState, Get-FedDefenderStatus, Update-FedDefenderDefinitions, Get-FedOSUpdates, Get-FedOSScanState, Split-FedOSUpdates, Invoke-FedElevatedOSScan, Get-FedOSScanCache, Save-FedOSScanCache, Clear-FedOSScanCache, Test-FedOSScanCacheCurrent, Get-FedOSInstallResult, Save-FedOSInstallResult, Clear-FedOSInstallResult, Get-FedUpdateResultText, Test-FedRestartOwedToWindowsUpdate, Get-FedUpdateArticleUrl, Get-FedUpdateArticleNote, Remove-FedUrlLocale, Install-FedOSUpdates, Get-FedWingetPath, Get-FedWingetUpdates, Update-FedWingetPackages, Invoke-FedWingetProcess, Get-FedWingetOutcomes, Test-FedInstallerStoppedForOpenApp, Sync-FedStoreApps, Get-FedStoreStatus, Get-FedVersion, Set-FedVersionStamp, Get-FedLatestRelease, Get-FedVersionStatus, Compare-FedVersion, Get-FedReleaseNotes, Invoke-FedSelfUpdate, Get-FedUpdateChannel, Get-FedChannelBranch, Get-FedInstallScriptUrl, Get-FedBranchPosition -ErrorAction SilentlyContinue
