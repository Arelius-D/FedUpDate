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

    # The guard runs as SYSTEM, and its definition is readable only by SYSTEM
    # and administrators. An ordinary session therefore cannot see it at all and
    # is told nothing rather than told it is missing: reporting an absent guard
    # from a session that could never have seen one would mark every standard
    # user as permanently drifted.
    #
    # A guard that is genuinely absent still counts as drift, but only when this
    # session is able to tell the difference.
    $canSeeTasks = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $wantsGuard = [bool]$config.watchdog.enforceOnBoot

    if (-not $taskInstalled -and -not $canSeeTasks) {
        $taskState = "Not visible without elevation"
    }

    $taskExpected = if ($wantsGuard) { "Ready" } else { "Not required" }
    $taskDrifted = $wantsGuard -and $canSeeTasks -and (-not $taskInstalled -or $taskState -eq "Disabled")

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

    # An enforcement that found everything already in place used to say nothing
    # at all, leaving several silent seconds in the log with no account of what
    # had been looked at. Recording nothing is right; saying nothing is not.
    $applied = @($tx.Changes).Count
    $managed = @(Get-FedManagedState).Count
    if ($applied -eq 0) {
        Write-FedLog "Checked $managed setting(s). All were already as they should be." -Level "INFO" -Component "Watchdog"
    } else {
        Write-FedLog "Checked $managed setting(s). $applied needed putting back." -Level "INFO" -Component "Watchdog"
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

function Get-FedManagedState {
    <#
    .SYNOPSIS
        Every setting this application is capable of changing.
    .DESCRIPTION
        The enforcement and the baseline have to describe the same settings, or
        the record will be of one thing and the change of another. Both read
        this list, so a setting cannot be enforced without being recorded first.
    #>
    [CmdletBinding()]
    param()

    $auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $auPathUser = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"

    return @(
        [PSCustomObject]@{ Kind = "Registry"; KeyPath = $auPath;     ValueName = "NoAutoUpdate";                    Value = 1; ValueType = "DWord" }
        [PSCustomObject]@{ Kind = "Registry"; KeyPath = $auPath;     ValueName = "AUOptions";                       Value = 2; ValueType = "DWord" }
        [PSCustomObject]@{ Kind = "Registry"; KeyPath = $auPath;     ValueName = "NoAutoRebootWithLoggedOnUsers";   Value = 1; ValueType = "DWord" }
        [PSCustomObject]@{ Kind = "Registry"; KeyPath = $auPath;     ValueName = "AlwaysAutoRebootAtScheduledTime"; Value = 0; ValueType = "DWord" }
        [PSCustomObject]@{ Kind = "Registry"; KeyPath = $auPathUser; ValueName = "NoAutoUpdate";                    Value = 1; ValueType = "DWord" }
        [PSCustomObject]@{ Kind = "Registry"; KeyPath = $auPathUser; ValueName = "AUOptions";                       Value = 2; ValueType = "DWord" }
        [PSCustomObject]@{ Kind = "Service";  ServiceName = "wuauserv" }
        [PSCustomObject]@{ Kind = "Service";  ServiceName = "DoSvc" }
        [PSCustomObject]@{ Kind = "Task";     TaskPath = "\Microsoft\Windows\UpdateOrchestrator\"; TaskName = "Schedule Scan" }
        [PSCustomObject]@{ Kind = "Task";     TaskPath = "\Microsoft\Windows\UpdateOrchestrator\"; TaskName = "Report policies" }
        [PSCustomObject]@{ Kind = "Task";     TaskPath = "\Microsoft\Windows\WindowsUpdate\";      TaskName = "Scheduled Start" }
    )
}

function Install-FedWatchdogTask {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf,

        # How often the guard re-asserts the desired state while the machine is
        # running. Windows undoes it within minutes, so checking only at startup
        # means the shield is down for almost the whole session.
        [Parameter()]
        [int]$IntervalMinutes = 15
    )

    $taskName = "FedUpDate-Watchdog-Enforcer"
    $scriptRoot = Split-Path -Parent $PSScriptRoot
    $cliScript = Join-Path $scriptRoot "fedupdate.ps1"
    
    $pwshPath = (Get-Process -Id $PID).Path
    $actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" watchdog enforce"

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would register Scheduled Task '$taskName' as SYSTEM, at startup and every $IntervalMinutes minutes: $pwshPath $actionArgs" -Level "WHATIF" -Component "Watchdog"
        return $true
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-FedLog "Administrator rights are required to register the boot guard under the SYSTEM account. Run 'fedupdate watchdog enforce' once from an elevated session." -Level "WARN" -Component "Watchdog"
        return $false
    }

    # A guard that is already registered and enabled needs nothing doing to it.
    # This used to register unconditionally on every enforcement, and one of the
    # triggers it wrote started a minute after registration. So each enforcement
    # scheduled the next one a minute out, that one enforced and registered
    # again, and the guard ran every sixty seconds for the life of the machine
    # while reporting on each line that it runs every fifteen minutes.
    $already = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($already -and $already.State -ne "Disabled") {
        return $true
    }

    try {
        # Registered under SYSTEM, matching the update scheduler. The task runs
        # in session 0, so the boot guard never shows a console window and never
        # raises a UAC prompt when the user signs in.
        $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $actionArgs
        # Startup alone is not enough. Windows repairs its own update
        # components while the machine is running, not only across a restart, so
        # a guard that fires once at boot loses the setting minutes later and
        # does not look again until the next one. Re-asserting on an interval is
        # what makes this a watchdog rather than a boot script.
        # Two triggers, because one is not enough on its own. The boot trigger
        # covers a restart, but its repetition only starts counting once it has
        # fired, so on a machine that is already running it would not re-assert
        # until the next boot. The second trigger starts now and repeats for the
        # life of the session, which is when Windows actually undoes the work.
        $bootTrigger = New-ScheduledTaskTrigger -AtStartup
        $bootTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)).Repetition

        # Starts one interval from now rather than one minute from now. A minute
        # was chosen so the guard would take effect promptly, but registration
        # happens during enforcement, so it only ever scheduled another
        # enforcement a minute later and never stopped.
        $nowTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($IntervalMinutes) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

        $trigger = @($bootTrigger, $nowTrigger)
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew

        # -ErrorAction Stop because registration can fail without throwing, and
        # the result is piped away. Without it a refusal is silently discarded.
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

        # Asking for it back is the only proof it is there. Reporting a guard
        # that was never registered is worse than reporting no guard at all,
        # because it is the answer that stops anybody looking.
        $registered = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $registered) {
            Write-FedLog "The boot guard reported no error but is not present afterwards. Nothing will re-apply your settings at startup." -Level "ERROR" -Component "Watchdog"
            return $false
        }

        Write-FedLog "Registered watchdog task '$taskName' (SYSTEM, session 0), at startup and every $IntervalMinutes minutes, verified present." -Level "SUCCESS" -Component "Watchdog"
        return $true
    } catch {
        Write-FedLog "Failed to register the boot guard: $($_.Exception.Message)" -Level "ERROR" -Component "Watchdog"
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
