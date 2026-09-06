# ==============================================================================
# FedUpDate Anti-Tamper & Policy Watchdog Engine
# Audits, locks down, and enforces user update rules against Windows silent reversions
# Full Rollback Ledger recording and -WhatIf support
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\RollbackEngine.ps1"

function Get-FedWatchdogAudit {
    <#
    .SYNOPSIS
        Reads every setting the shield manages and reports what is there.
    .DESCRIPTION
        This used to examine three of the eleven settings the shield changes,
        skip the rest without saying so, and report the machine in its desired
        state on the strength of that. It also never asked for the rights it
        needs to read the scheduled tasks, so those were not checked at all
        rather than checked and found wanting.

        An audit reads and reports. It changes nothing.
    #>
    [CmdletBinding()]
    param(
        # Reading the scheduled tasks needs elevation. Asked for it, an
        # ordinary session re-enters elevated so the audit is complete rather
        # than quietly partial.
        [Parameter()]
        [switch]$NoElevate
    )

    $config = Get-FedConfig
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Reading the scheduled tasks needs elevation. An ordinary session cannot
    # see them, so an audit run from one examined the settings it could reach
    # and said nothing about the rest, which is not an audit. It asks now, the
    # way checking for Windows updates asks, and the answer comes back through a
    # file because the elevated run is a separate process that then exits.
    if (-not $isAdmin -and -not $NoElevate) {
        try {
            $scriptRoot = Split-Path -Parent $PSScriptRoot
            $cliScript = Join-Path $scriptRoot "fedupdate.ps1"
            $resultFile = Join-Path (Get-FedDataDirectory) "watchdog_audit.json"
            if (Test-Path $resultFile) { Remove-Item $resultFile -Force -ErrorAction SilentlyContinue }

            Write-FedLog "The scheduled tasks cannot be read without elevation. Asking for it so the audit is complete." -Level "INFO" -Component "Watchdog"
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" watchdog audit" -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop

            if ($null -ne $p -and $p.ExitCode -eq 0 -and (Test-Path $resultFile)) {
                $raw = Get-Content -Path $resultFile -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    Write-FedLog "Elevated audit finished." -Level "SUCCESS" -Component "Watchdog"
                    return ($raw | ConvertFrom-Json)
                }
            }
            Write-FedLog "The elevated audit did not return a result. Reporting only what this session can read." -Level "WARN" -Component "Watchdog"
        } catch {
            # Declining is an answer. The audit still runs, and says plainly
            # which settings it could not see.
            Write-FedLog "Elevation was declined. The scheduled tasks cannot be read, and are reported as unread rather than as correct." -Level "WARN" -Component "Watchdog"
        }
    }

    $items = [System.Collections.Generic.List[PSObject]]::new()
    $unread = 0

    Write-FedLog "Auditing the $((Get-FedManagedState).Count) settings the shield manages..." -Level "INFO" -Component "Watchdog"

    foreach ($m in (Get-FedManagedState)) {
        switch ($m.Kind) {
            "Registry" {
                # Whether this setting is wanted at all is the person's choice.
                $wanted = [bool]$config.watchdog.enabled
                $actual = $null
                if (Test-Path $m.KeyPath) {
                    $actual = (Get-ItemProperty -Path $m.KeyPath -Name $m.ValueName -ErrorAction SilentlyContinue).($m.ValueName)
                }
                $hive = if ($m.KeyPath -like "HKLM:*") { "HKLM" } else { "HKCU" }
                $drifted = $wanted -and ($actual -ne $m.Value)
                $items.Add([PSCustomObject]@{
                    Name     = "$hive policy: $($m.ValueName)"
                    Type     = "Registry"
                    Expected = if ($wanted) { [string]$m.Value } else { "not enforced" }
                    Actual   = if ($null -ne $actual) { [string]$actual } else { "not set" }
                    Drifted  = $drifted
                    Readable = $true
                })
            }

            "Service" {
                $wanted = if ($m.ServiceName -eq "wuauserv") { [bool]$config.watchdog.disableAutoUpdateService }
                          else { [bool]$config.watchdog.disableDeliveryOptimization }
                $svc = Get-Service -Name $m.ServiceName -ErrorAction SilentlyContinue
                $actual = if ($svc) { $svc.StartType.ToString() } else { "not present" }
                $drifted = $wanted -and ($actual -ne "Disabled")
                $items.Add([PSCustomObject]@{
                    Name     = "Service: $($m.ServiceName)"
                    Type     = "Service"
                    Expected = if ($wanted) { "Disabled" } else { "not enforced" }
                    Actual   = $actual
                    Drifted  = $drifted
                    Readable = $true
                })
            }

            "Task" {
                $wanted = [bool]$config.watchdog.disableUpdateOrchestrator
                $task = Get-ScheduledTask -TaskPath $m.TaskPath -TaskName $m.TaskName -ErrorAction SilentlyContinue
                # Absent and invisible look the same from an ordinary session,
                # and only one of them is a fact.
                $readable = ($null -ne $task) -or $isAdmin
                if (-not $readable) { $unread++ }
                $actual = if ($task) { $task.State.ToString() } elseif ($isAdmin) { "not present" } else { "cannot be read without elevation" }
                $drifted = $wanted -and $readable -and ($actual -ne "Disabled")
                $items.Add([PSCustomObject]@{
                    Name     = "Task: $($m.TaskName)"
                    Type     = "ScheduledTask"
                    Expected = if ($wanted) { "Disabled" } else { "not enforced" }
                    Actual   = $actual
                    Drifted  = $drifted
                    Readable = $readable
                })
            }
        }
    }

    # The shield's own boot guard. Not one of the managed settings, but the
    # thing that keeps them applied, and nothing was showing whether it exists.
    $guardTask = Get-ScheduledTask -TaskName "FedUpDate-Watchdog-Enforcer" -ErrorAction SilentlyContinue
    $guardWanted = [bool]$config.watchdog.enforceOnBoot
    $guardReadable = ($null -ne $guardTask) -or $isAdmin
    if (-not $guardReadable) { $unread++ }
    $guardState = if ($guardTask) { $guardTask.State.ToString() } elseif ($isAdmin) { "not installed" } else { "cannot be read without elevation" }
    $items.Add([PSCustomObject]@{
        Name     = "Boot guard (FedUpDate-Watchdog-Enforcer)"
        Type     = "BootGuard"
        Expected = if ($guardWanted) { "Ready" } else { "not required" }
        Actual   = $guardState
        Drifted  = $guardWanted -and $guardReadable -and ($guardState -ne "Ready")
        Readable = $guardReadable
    })

    foreach ($i in $items) {
        if (-not $i.Readable) {
            Write-FedLog "$($i.Name): could not be read from this session." -Level "WARN" -Component "Watchdog"
        } elseif ($i.Drifted) {
            Write-FedLog "$($i.Name): expected $($i.Expected), found $($i.Actual)." -Level "WARN" -Component "Watchdog"
        } else {
            Write-FedLog "$($i.Name): $($i.Actual)." -Level "INFO" -Component "Watchdog"
        }
    }

    $drifted = @($items | Where-Object { $_.Drifted })
    if ($unread -gt 0) {
        Write-FedLog "Audit finished. $($drifted.Count) setting(s) have drifted. $unread could not be read from this session; run the audit elevated to see them." -Level "WARN" -Component "Watchdog"
    } else {
        Write-FedLog "Audit finished. $($drifted.Count) of $($items.Count) setting(s) have drifted." -Level $(if ($drifted.Count -gt 0) { "WARN" } else { "SUCCESS" }) -Component "Watchdog"
    }

    $result = [PSCustomObject]@{
        HasDrifted   = ($drifted.Count -gt 0)
        DriftCount   = $drifted.Count
        UnreadCount  = $unread
        NeedsElevation = ($unread -gt 0)
        GuardState   = $guardState
        GuardInstalled = ($null -ne $guardTask)
        DriftItems   = @($drifted)
        AuditItems   = @($items)
    }

    # An elevated run is a separate process that exits, so it leaves its answer
    # where the session that asked for it can pick it up.
    if ($isAdmin) {
        try {
            $result | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path (Get-FedDataDirectory) "watchdog_audit.json") -Encoding UTF8 -ErrorAction Stop
        } catch { }
    }

    return $result
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
    $script:FedEnforceApplied = 0
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
    # What was recorded is not what was applied. Since a setting's original is
    # written down only once, this counted zero on every run after the first and
    # announced that nothing had needed doing, directly beneath the lines saying
    # it had just set six registry values and reconfigured a service.
    $managed = @(Get-FedManagedState).Count
    if ($script:FedEnforceApplied -eq 0) {
        Write-FedLog "Checked $managed setting(s). All were already as they should be." -Level "INFO" -Component "Watchdog"
    } else {
        Write-FedLog "Checked $managed setting(s). $($script:FedEnforceApplied) needed putting back." -Level "INFO" -Component "Watchdog"
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
