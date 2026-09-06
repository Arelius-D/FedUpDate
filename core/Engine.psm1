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

    $osUpdates = @(Get-FedOSUpdates -IncludeDefender:([bool]$IncludeDefender))
    $wingetUpdates = @(Get-FedWingetUpdates)
    $storeStatus = Get-FedStoreStatus
    $rebootState = Get-FedRebootState
    $watchdogAudit = Get-FedWatchdogAudit
    $config = Get-FedConfig

    # Asked once. Two calls could straddle a change and disagree with each other.
    $osScanState = Get-FedOSScanState

    $summary = [PSCustomObject]@{
        Timestamp          = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        OSScanBlocked      = [bool]$osScanState.Blocked
        OSScanReason       = [string]$osScanState.Reason
        OSScanCached       = [bool]$osScanState.Cached
        OSScanCheckedAt    = [string]$osScanState.CheckedAt
        OSUpdateCount      = [int]@($osUpdates).Count
        OSUpdates          = @($osUpdates)
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

function Start-FedUpdate {
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

        [Parameter()]
        [string]$RebootPolicyOverride,

        [Parameter()]
        [switch]$WhatIf
    )

    $config = Get-FedConfig

    $runOS = $OS -or $All -or ($config.engines.osUpdates -and -not ($OS -or $Winget -or $Store))
    $runWinget = $Winget -or $All -or ($config.engines.wingetApps -and -not ($OS -or $Winget -or $Store))
    $runStore = $Store -or $All -or ($config.engines.storeApps -and -not ($OS -or $Winget -or $Store))

    Write-FedLog "=== Starting Unified Update Run (OS: $runOS, Winget: $runWinget, Store: $runStore, WhatIf: $WhatIf) ===" -Level "INFO" -Component "Engine"

    $results = [PSCustomObject]@{
        OSResult     = $null
        WingetResult = $null
        StoreResult  = $null
        RebootResult = $null
    }

    # 1. Windows OS & Defender Updates
    if ($runOS) {
        Write-FedLog "--- [1/3] Operating System & Defender Definitions ---" -Level "INFO" -Component "Engine"
        $results.OSResult = Install-FedOSUpdates -UpdateDefender:$true -WhatIf:$WhatIf
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
    if ($config.watchdog.enabled) {
        Write-FedLog "--- Enforcing Anti-Tamper State after updates ---" -Level "INFO" -Component "Engine"
        Enforce-FedWatchdog -WhatIf:$WhatIf | Out-Null
    }

    # 5. Smart Reboot Evaluation
    Write-FedLog "--- Checking Reboot Requirements ---" -Level "INFO" -Component "Engine"
    $results.RebootResult = Invoke-FedRebootPolicy -PolicyOverride $RebootPolicyOverride -WhatIf:$WhatIf

    Write-FedLog "=== Unified Update Run Completed ===" -Level "SUCCESS" -Component "Engine"
    return $results
}

Export-ModuleMember -Function Start-FedScan, Start-FedUpdate, Write-FedLog, Get-FedFriendlyAge, Get-FedLogs, Clear-FedLogs, Get-FedLogDirectory, Get-FedDataDirectory, Get-FedDefaultConfig, Get-FedConfig, Set-FedConfig, Update-FedConfig, Reset-FedConfig, Get-FedRebootState, Get-FedRebootSignalData, Get-FedRebootVerdict, ConvertFrom-FedPendingFileRename, Invoke-FedRebootPolicy, Get-FedWatchdogAudit, Get-FedManagedState, Save-FedInstallBaseline, Enforce-FedWatchdog, Install-FedWatchdogTask, Uninstall-FedWatchdogTask, Test-FedWatchdogTaskExists, Get-FedScheduleTask, Set-FedScheduleTask, Remove-FedScheduleTask, Get-FedLedger, Save-FedLedger, New-FedTransaction, Record-FedRegistryChange, Record-FedServiceChange, Record-FedTaskChange, Record-FedFileBackup, Commit-FedTransaction, Restore-FedState, Get-FedDefenderStatus, Update-FedDefenderDefinitions, Get-FedOSUpdates, Get-FedOSScanState, Invoke-FedElevatedOSScan, Get-FedOSScanCache, Save-FedOSScanCache, Clear-FedOSScanCache, Get-FedOSInstallResult, Save-FedOSInstallResult, Clear-FedOSInstallResult, Get-FedUpdateResultText, Get-FedUpdateArticleUrl, Get-FedUpdateArticleNote, Remove-FedUrlLocale, Install-FedOSUpdates, Get-FedWingetPath, Get-FedWingetUpdates, Update-FedWingetPackages, Invoke-FedWingetProcess, Sync-FedStoreApps, Get-FedStoreStatus, Get-FedVersion, Set-FedVersionStamp, Get-FedLatestRelease, Get-FedVersionStatus, Compare-FedVersion, Get-FedReleaseNotes, Invoke-FedSelfUpdate, Get-FedUpdateChannel, Get-FedChannelBranch, Get-FedInstallScriptUrl, Get-FedBranchPosition -ErrorAction SilentlyContinue
