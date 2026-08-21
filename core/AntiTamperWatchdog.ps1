# ==============================================================================
# FedUpDate Anti-Tamper & Policy Watchdog Engine
# Audits, locks down, and enforces user update rules against Windows silent reversions
# Full Rollback Ledger recording and -WhatIf support
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\RollbackEngine.ps1"

function Get-FedWatchdogAudit {
    [CmdletBinding()]
    param()

    $config = Get-FedConfig
    $driftItems = [System.Collections.Generic.List[PSObject]]::new()
    $auditItems = [System.Collections.Generic.List[PSObject]]::new()

    # 1. Check Windows Update Service (wuauserv)
    $wuService = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
    if ($wuService) {
        $expected = if ($config.watchdog.disableAutoUpdateService) { "Disabled" } else { "Manual" }
        $actual = $wuService.StartType.ToString()
        $isDrifted = ($config.watchdog.disableAutoUpdateService -and $actual -ne "Disabled")
        
        $item = [PSCustomObject]@{
            Name     = "Windows Update Service (wuauserv)"
            Type     = "Service"
            Expected = $expected
            Actual   = $actual
            Status   = $wuService.Status.ToString()
            Drifted  = $isDrifted
        }
        $auditItems.Add($item)
        if ($isDrifted) { $driftItems.Add($item) }
    }

    # 2. Check Delivery Optimization Service (DoSvc)
    $doService = Get-Service -Name "DoSvc" -ErrorAction SilentlyContinue
    if ($doService) {
        $expected = if ($config.watchdog.disableDeliveryOptimization) { "Disabled" } else { "Manual" }
        $actual = $doService.StartType.ToString()
        $isDrifted = ($config.watchdog.disableDeliveryOptimization -and $actual -ne "Disabled")
        
        $item = [PSCustomObject]@{
            Name     = "Delivery Optimization (DoSvc)"
            Type     = "Service"
            Expected = $expected
            Actual   = $actual
            Status   = $doService.Status.ToString()
            Drifted  = $isDrifted
        }
        $auditItems.Add($item)
        if ($isDrifted) { $driftItems.Add($item) }
    }

    # 3. Check Windows Update Policy Registry (AUOptions / NoAutoUpdate)
    $auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $auPathUser = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $noAutoUpdateVal = $null
    if (Test-Path $auPath) {
        $noAutoUpdateVal = (Get-ItemProperty $auPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue).NoAutoUpdate
    }
    if ($null -eq $noAutoUpdateVal -and (Test-Path $auPathUser)) {
        $noAutoUpdateVal = (Get-ItemProperty $auPathUser -Name "NoAutoUpdate" -ErrorAction SilentlyContinue).NoAutoUpdate
    }
    $expectedVal = if ($config.watchdog.enabled) { 1 } else { 0 }
    $regDrifted = ($config.watchdog.enabled -and $noAutoUpdateVal -ne 1)

    $itemReg = [PSCustomObject]@{
        Name     = "Group Policy: NoAutoUpdate (Registry)"
        Type     = "Registry"
        Expected = "1 (Enforced Manual/FedUpDate)"
        Actual   = if ($null -ne $noAutoUpdateVal) { $noAutoUpdateVal.ToString() } else { "Not Set (Windows Default)" }
        Status   = "OK"
        Drifted  = $regDrifted
    }
    $auditItems.Add($itemReg)
    if ($regDrifted) { $driftItems.Add($itemReg) }

    # 4. Check Scheduled Task: FedUpDate On-Boot Guard
    $guardTask = Get-ScheduledTask -TaskName "FedUpDate-Watchdog-Enforcer" -ErrorAction SilentlyContinue
    $taskInstalled = ($null -ne $guardTask)
    $taskState = if ($taskInstalled) { $guardTask.State.ToString() } else { "Not Installed" }
    $taskExpected = if ($taskInstalled) { "Ready" } else { "Optional" }
    $taskDrifted = ($taskInstalled -and $taskState -eq "Disabled")

    $itemTask = [PSCustomObject]@{
        Name     = "FedUpDate Boot Persistence Task"
        Type     = "ScheduledTask"
        Expected = $taskExpected
        Actual   = $taskState
        Status   = $taskState
        Drifted  = $taskDrifted
    }
    $auditItems.Add($itemTask)
    if ($taskDrifted) { $driftItems.Add($itemTask) }

    return [PSCustomObject]@{
        HasDrifted = ($driftItems.Count -gt 0)
        DriftCount = $driftItems.Count
        DriftItems = @($driftItems)
        AuditItems = @($auditItems)
    }
}

function Enforce-FedWatchdog {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf
    )

    Write-FedLog "Executing Anti-Tamper State Enforcement..." -Level "INFO" -Component "Watchdog"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $WhatIf) {
        try {
            $scriptRoot = Split-Path -Parent $PSScriptRoot
            $cliScript = Join-Path $scriptRoot "fedupdate.ps1"
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" watchdog enforce" -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
            if ($null -ne $p -and $p.ExitCode -eq 0) {
                Write-FedLog "Elevated anti-tamper enforcement completed successfully." -Level "SUCCESS" -Component "Watchdog"
                return $true
            }
        } catch {
            Write-FedLog "Could not elevate automatically ($($_.Exception.Message)). Proceeding with direct enforcement..." -Level "WARN" -Component "Watchdog"
        }
    }

    $config = Get-FedConfig
    $tx = New-FedTransaction -Description "Anti-Tamper Watchdog Policy Enforcement"

    # 1. Group Policy Registry Keys for Windows Update (HKLM & HKCU)
    $auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $auPathUser = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if ($config.watchdog.enabled) {
        Record-FedRegistryChange -Transaction $tx -KeyPath $auPath -ValueName "NoAutoUpdate" -NewValue 1 -ValueType "DWord" -WhatIf:$WhatIf
        Record-FedRegistryChange -Transaction $tx -KeyPath $auPath -ValueName "AUOptions" -NewValue 2 -ValueType "DWord" -WhatIf:$WhatIf
        Record-FedRegistryChange -Transaction $tx -KeyPath $auPath -ValueName "NoAutoRebootWithLoggedOnUsers" -NewValue 1 -ValueType "DWord" -WhatIf:$WhatIf
        Record-FedRegistryChange -Transaction $tx -KeyPath $auPath -ValueName "AlwaysAutoRebootAtScheduledTime" -NewValue 0 -ValueType "DWord" -WhatIf:$WhatIf
        Record-FedRegistryChange -Transaction $tx -KeyPath $auPathUser -ValueName "NoAutoUpdate" -NewValue 1 -ValueType "DWord" -WhatIf:$WhatIf
        Record-FedRegistryChange -Transaction $tx -KeyPath $auPathUser -ValueName "AUOptions" -NewValue 2 -ValueType "DWord" -WhatIf:$WhatIf
    }

    # 2. Services Configuration
    if ($config.watchdog.disableAutoUpdateService) {
        Record-FedServiceChange -Transaction $tx -ServiceName "wuauserv" -NewStartType "Disabled" -WhatIf:$WhatIf
    }
    if ($config.watchdog.disableDeliveryOptimization) {
        Record-FedServiceChange -Transaction $tx -ServiceName "DoSvc" -NewStartType "Disabled" -WhatIf:$WhatIf
    }

    # 3. Scheduled Tasks (Windows Update background triggers)
    $tasksToDisable = @(
        @{ Path = "\Microsoft\Windows\UpdateOrchestrator\"; Name = "Schedule Scan" },
        @{ Path = "\Microsoft\Windows\UpdateOrchestrator\"; Name = "Report policies" },
        @{ Path = "\Microsoft\Windows\WindowsUpdate\"; Name = "Scheduled Start" }
    )

    if ($config.watchdog.disableUpdateOrchestrator) {
        foreach ($t in $tasksToDisable) {
            Record-FedTaskChange -Transaction $tx -TaskPath $t.Path -TaskName $t.Name -NewState "Disable" -WhatIf:$WhatIf
        }
    }

    # Commit Transaction to ledger for complete rollback capability
    Commit-FedTransaction -Transaction $tx -WhatIf:$WhatIf

    # 4. Enforce On-Boot Task if enabled
    if ($config.watchdog.enforceOnBoot) {
        Install-FedWatchdogTask -WhatIf:$WhatIf
    }

    Write-FedLog "Anti-Tamper state enforcement completed successfully." -Level "SUCCESS" -Component "Watchdog"
    return $true
}

function Install-FedWatchdogTask {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf
    )

    $taskName = "FedUpDate-Watchdog-Enforcer"
    $scriptRoot = Split-Path -Parent $PSScriptRoot
    $cliScript = Join-Path $scriptRoot "fedupdate.ps1"
    
    $pwshPath = (Get-Process -Id $PID).Path
    $actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" watchdog enforce"

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would register Scheduled Task '$taskName' at startup as SYSTEM: $pwshPath $actionArgs" -Level "WHATIF" -Component "Watchdog"
        return $true
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-FedLog "Administrator rights are required to register the boot guard under the SYSTEM account. Run 'fedupdate watchdog enforce' once from an elevated session." -Level "WARN" -Component "Watchdog"
        return $false
    }

    try {
        # Registered under SYSTEM, matching the update scheduler. The task runs
        # in session 0, so the boot guard never shows a console window and never
        # raises a UAC prompt when the user signs in.
        $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $actionArgs
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-FedLog "Registered silent on-boot watchdog task '$taskName' (SYSTEM, session 0)." -Level "SUCCESS" -Component "Watchdog"
        return $true
    } catch {
        Write-FedLog "Failed to register watchdog task: $_" -Level "WARN" -Component "Watchdog"
        return $false
    }
}

function Uninstall-FedWatchdogTask {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf
    )

    $taskName = "FedUpDate-Watchdog-Enforcer"
    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would unregister Scheduled Task '$taskName'" -Level "WHATIF" -Component "Watchdog"
        return $true
    }

    try {
        $null = & schtasks.exe /Delete /TN $taskName /F 2>&1
        Write-FedLog "Unregistered watchdog task '$taskName'." -Level "SUCCESS" -Component "Watchdog"
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function Get-FedWatchdogAudit, Enforce-FedWatchdog, Install-FedWatchdogTask, Uninstall-FedWatchdogTask -ErrorAction SilentlyContinue
