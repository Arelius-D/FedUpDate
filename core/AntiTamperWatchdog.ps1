# ==============================================================================
# FedUpDate Anti-Tamper & Policy Watchdog Engine
# Audits, locks down, and enforces user update rules against Windows silent reversions
# Full Rollback Ledger recording and -WhatIf support
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\RollbackEngine.ps1"

function Get-FedWatchdogStateFile {
    return Join-Path (Get-FedDataDirectory) "watchdog_state.json"
}

function Get-FedWatchdogState {
    <#
    .SYNOPSIS
        What this installation has recorded about its own guard.
    #>
    [CmdletBinding()]
    param()

    $f = Get-FedWatchdogStateFile
    if (-not (Test-Path $f)) { return $null }
    try {
        $raw = Get-Content -Path $f -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Set-FedWatchdogState {
    <#
    .SYNOPSIS
        Records something about the guard, leaving the rest as it was.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    $current = Get-FedWatchdogState
    $state = @{
        Installed       = $false
        InstalledAt     = $null
        IntervalMinutes = 15
        LastRun         = $null
        LastRunApplied  = 0
        Suspended       = $false
        SuspendedAt     = $null
    }
    if ($current) {
        foreach ($k in @($state.Keys)) {
            if ($null -ne $current.PSObject.Properties[$k]) { $state[$k] = $current.$k }
        }
    }
    foreach ($k in $Values.Keys) { $state[$k] = $Values[$k] }

    try {
        [PSCustomObject]$state | ConvertTo-Json -Depth 4 | Set-Content -Path (Get-FedWatchdogStateFile) -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function Get-FedWatchdogStatus {
    <#
    .SYNOPSIS
        Whether the guard is installed, when it last ran and when it runs next.
    .DESCRIPTION
        Somebody with the application open should be able to see whether the
        thing that defends their settings is there and working, without running
        an audit to find out and without handing over administrator rights to
        ask. There was no way to see any of it, so the only way to be sure the
        guard was in place was to enforce again, whether or not it already was.

        None of this needs elevation, because the application writes down what
        it did rather than going to ask Windows about a task an ordinary session
        is not allowed to see.
    #>
    [CmdletBinding()]
    param()

    $config = Get-FedConfig
    $state = Get-FedWatchdogState
    $interval = if ($state -and $state.IntervalMinutes) { [int]$state.IntervalMinutes }
                elseif ($config.watchdog.PSObject.Properties['intervalMinutes']) { [int]$config.watchdog.intervalMinutes }
                else { 15 }

    $installed = [bool]($state -and $state.Installed)
    $lastRun = $null
    if ($state -and -not [string]::IsNullOrWhiteSpace([string]$state.LastRun)) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$state.LastRun, [ref]$parsed)) { $lastRun = $parsed }
    }

    $nextRun = $null
    $minutesUntil = $null
    if ($installed -and $lastRun) {
        $nextRun = $lastRun.AddMinutes($interval)
        $minutesUntil = [int][math]::Ceiling(($nextRun - (Get-Date)).TotalMinutes)
        # Overdue means the machine was asleep or the task has not fired yet.
        if ($minutesUntil -lt 0) { $minutesUntil = 0 }
    }

    return [PSCustomObject]@{
        Wanted          = [bool]$config.watchdog.enforceOnBoot
        Installed       = $installed
        InstalledAt     = if ($state) { $state.InstalledAt } else { $null }
        IntervalMinutes = $interval
        LastRun         = if ($lastRun) { $lastRun.ToString("o") } else { $null }
        LastRunAgo      = if ($lastRun) { Get-FedFriendlyAge -Iso $lastRun.ToString("o") } else { $null }
        LastRunApplied  = if ($state -and $null -ne $state.LastRunApplied) { [int]$state.LastRunApplied } else { 0 }
        NextRun         = if ($nextRun) { $nextRun.ToString("o") } else { $null }
        MinutesUntilNext = $minutesUntil
    }
}

function Format-FedWatchdogStatus {
    <#
    .SYNOPSIS
        The guard's state in plain lines, for whichever interface is asking.
    #>
    [CmdletBinding()]
    param()

    $st = Get-FedWatchdogStatus
    $lines = @()

    if (-not $st.Wanted) {
        $lines += "Boot guard      : turned off in settings"
        return $lines
    }

    if ($st.Installed) {
        $lines += "Boot guard      : installed and scheduled"
    } else {
        $lines += "Boot guard      : not installed, so nothing re-applies these settings"
    }

    $lines += "Runs every      : $($st.IntervalMinutes) minutes"

    if ($st.LastRun) {
        $put = if ($st.LastRunApplied -gt 0) { ", put back $($st.LastRunApplied) setting(s)" } else { ", nothing needed putting back" }
        $lines += "Last checked    : $($st.LastRunAgo)$put"
    } else {
        $lines += "Last checked    : never"
    }

    if ($null -ne $st.MinutesUntilNext) {
        $when = if ($st.MinutesUntilNext -le 0) { "due now" } else { "in $($st.MinutesUntilNext) minute(s)" }
        $lines += "Next check      : $when"
    } else {
        $lines += "Next check      : not scheduled"
    }

    return $lines
}

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
        # Reading the scheduled tasks needs elevation, and asking for it puts a
        # prompt in front of somebody. That is fine when they have just pressed
        # Run Audit and are waiting for an answer. It is not fine when the audit
        # is being taken as part of something else, and it was: a scan includes
        # one, and starting the interface used to trigger a scan, so opening the
        # application asked for administrator rights before anybody had touched
        # anything. Elevation is asked for only when this is what was wanted.
        [Parameter()]
        [switch]$Elevate
    )

    $config = Get-FedConfig
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Reading the scheduled tasks needs elevation. An ordinary session cannot
    # see them, so an audit run from one examined the settings it could reach
    # and said nothing about the rest, which is not an audit. It asks now, the
    # way checking for Windows updates asks, and the answer comes back through a
    # file because the elevated run is a separate process that then exits.
    if ($Elevate -and -not $isAdmin) {
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

function Test-FedWatchdogSuspended {
    <#
    .SYNOPSIS
        Whether an update run currently has the shield lifted.
    .DESCRIPTION
        True only for a recent, unexpired lift. Two hours is longer than any
        run should take and short enough that a run which crashed without
        restoring does not leave the guard standing down indefinitely: the next
        guard tick after expiry re-arms the shield as usual.
    #>
    [CmdletBinding()]
    param()

    $state = Get-FedWatchdogState
    if ($null -eq $state -or -not $state.Suspended) { return $false }

    try {
        $since = [datetime]::Parse([string]$state.SuspendedAt)
        return ((Get-Date) - $since).TotalHours -lt 2
    } catch {
        return $false
    }
}

function Suspend-FedWatchdog {
    <#
    .SYNOPSIS
        Lifts the shield so Windows Update can detect, download and install.
    .DESCRIPTION
        The exact inverse of enforcement, for the duration of an update run.
        With the shield up, Windows never refreshes its own update catalogue,
        so a scan reads a frozen list and reports nothing while the system's
        update screen shows a new KB. Everything that stops detection and
        installation is put back to the Windows default here.

        Two settings are deliberately left enforced: the two that stop Windows
        rebooting on its own. They do not block updating, and lifting them
        during an install is how a machine restarts in the middle of one.

        Nothing here is written to the ledger. This is a temporary lift, not a
        change of state, and recording it is how a later rollback ends up
        re-applying values it was meant to remove.
    #>
    [CmdletBinding()]
    param()

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-FedLog "The shield cannot be lifted without elevation." -Level "WARN" -Component "Watchdog"
        return $false
    }

    $keepEnforced = @("NoAutoRebootWithLoggedOnUsers", "AlwaysAutoRebootAtScheduledTime")
    $lifted = 0

    foreach ($item in @(Get-FedManagedState)) {
        try {
            switch ($item.Kind) {
                "Registry" {
                    if ($keepEnforced -contains $item.ValueName) { continue }
                    if (Test-Path $item.KeyPath) {
                        $existing = Get-ItemProperty -Path $item.KeyPath -Name $item.ValueName -ErrorAction SilentlyContinue
                        if ($null -ne $existing) {
                            Remove-ItemProperty -Path $item.KeyPath -Name $item.ValueName -Force -ErrorAction Stop
                            $lifted++
                        }
                    }
                }
                "Service" {
                    $svc = Get-Service -Name $item.ServiceName -ErrorAction SilentlyContinue
                    if ($null -eq $svc) { continue }
                    if ($item.ServiceName -eq "wuauserv") {
                        if ($svc.StartType -eq "Disabled") { Set-Service -Name $svc.Name -StartupType Manual -ErrorAction Stop; $lifted++ }
                        if ($svc.Status -ne "Running") { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue }
                    } elseif ($svc.StartType -eq "Disabled") {
                        Set-Service -Name $svc.Name -StartupType Automatic -ErrorAction Stop
                        $lifted++
                    }
                }
                "Task" {
                    $task = Get-ScheduledTask -TaskPath $item.TaskPath -TaskName $item.TaskName -ErrorAction SilentlyContinue
                    if ($null -ne $task -and $task.State -eq "Disabled") {
                        Enable-ScheduledTask -TaskPath $item.TaskPath -TaskName $item.TaskName -ErrorAction Stop | Out-Null
                        $lifted++
                    }
                }
            }
        } catch {
            Write-FedLog "Could not lift $($item.Kind) $($item.ValueName)$($item.ServiceName)$($item.TaskName): $_" -Level "WARN" -Component "Watchdog"
        }
    }

    Set-FedWatchdogState -Values @{
        Suspended   = $true
        SuspendedAt = (Get-Date).ToString("o")
    }

    Write-FedLog "Shield lifted for the update run: $lifted setting(s) returned to the Windows default. Reboot protection stays on." -Level "INFO" -Component "Watchdog"
    return $true
}

function Invoke-FedWithShieldLifted {
    <#
    .SYNOPSIS
        Runs a scriptblock with the shield lifted, then restores it.
    .DESCRIPTION
        Restoration is in a finally block: if the work throws, is cancelled or
        times out, the shield still goes back up. Re-entrant, so a scan that
        runs inside an install does not lift twice or restore early.

        Without elevation, without the shield enabled, or under WhatIf, the
        work simply runs and nothing is touched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [switch]$WhatIf
    )

    if ($null -eq $script:FedShieldLiftDepth) { $script:FedShieldLiftDepth = 0 }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $config = Get-FedConfig
    $shieldOn = [bool]($config.watchdog -and $config.watchdog.enabled)

    if ($WhatIf -or -not $isAdmin -or -not $shieldOn) {
        return & $Action
    }

    if ($script:FedShieldLiftDepth -gt 0) {
        $script:FedShieldLiftDepth++
        try { return & $Action } finally { $script:FedShieldLiftDepth-- }
    }

    $script:FedShieldLiftDepth = 1
    [void](Suspend-FedWatchdog)
    try {
        return & $Action
    } finally {
        $script:FedShieldLiftDepth = 0
        # Cleared before enforcing, or enforcement would see the lift and
        # decline to do anything. Cleared even if enforcement then fails, so
        # the periodic guard becomes the backstop rather than a stale flag
        # standing it down.
        Set-FedWatchdogState -Values @{ Suspended = $false; SuspendedAt = $null }
        try {
            Write-FedLog "Restoring the shield after the update run." -Level "INFO" -Component "Watchdog"
            Enforce-FedWatchdog | Out-Null
            $script:FedShieldRestored = $true
        } catch {
            $script:FedShieldRestored = $false
            Write-FedLog "The shield could not be restored after the update run: $_ Run the watchdog enforce command. The periodic guard will also re-arm it." -Level "ERROR" -Component "Watchdog"
        }
    }
}

function Enforce-FedWatchdog {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf
    )

    Write-FedLog "Executing Anti-Tamper State Enforcement..." -Level "INFO" -Component "Watchdog"

    # An update run lifts the shield for its duration and records that it did.
    # This function is also what the boot guard runs every thirty minutes, and
    # an installation can take longer than that. Re-arming the shield here
    # would disable the update service underneath a download in progress. The
    # run restores the shield itself when it finishes, or when it fails.
    #
    # The record expires. A run that died without restoring leaves the flag
    # behind, and the guard must not honour a stale one forever.
    if (Test-FedWatchdogSuspended) {
        Write-FedLog "The shield is lifted for an update run in progress. Leaving it lifted; the run restores it." -Level "INFO" -Component "Watchdog"
        return $true
    }

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
    # Written down so any session can say when the guard last did anything,
    # without asking Windows about a task it is not allowed to see.
    Set-FedWatchdogState -Values @{
        LastRun        = (Get-Date).ToString("o")
        LastRunApplied = [int]$script:FedEnforceApplied
    }
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
        # Taken from configuration when not given, so somebody changing how
        # often the guard runs actually changes how often the guard runs.
        [Parameter()]
        [int]$IntervalMinutes = 0
    )

    if ($IntervalMinutes -le 0) {
        $cfg = Get-FedConfig
        $IntervalMinutes = if ($cfg.watchdog.PSObject.Properties['intervalMinutes']) { [int]$cfg.watchdog.intervalMinutes } else { 15 }
        if ($IntervalMinutes -le 0) { $IntervalMinutes = 15 }
    }

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
        # Already there, so nothing to write to Windows, but this installation
        # should still know it is there.
        Set-FedWatchdogState -Values @{ Installed = $true; IntervalMinutes = [int]$IntervalMinutes }
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

        Set-FedWatchdogState -Values @{
            Installed       = $true
            InstalledAt     = (Get-Date).ToString("o")
            IntervalMinutes = [int]$IntervalMinutes
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

    # Nothing to remove is a clean outcome, and an ordinary session cannot see
    # the task to tell, so the deletion is attempted and then checked.
    try {
        $null = & schtasks.exe /Delete /TN $taskName /F 2>&1
    } catch { }

    if (-not (Test-FedWatchdogTaskExists -TaskName $taskName)) {
        Set-FedWatchdogState -Values @{ Installed = $false }
        Write-FedLog "Unregistered watchdog task '$taskName'." -Level "SUCCESS" -Component "Watchdog"
        return $true
    }

    # The task runs as SYSTEM, and deleting it needs administrator rights.
    # Without them the deletion is refused, and that refusal used to be
    # discarded while success was reported anyway. So the guard outlived every
    # uninstall, kept running on its timer as SYSTEM, and went on re-applying
    # settings to a machine whose owner had removed the application. An
    # uninstalled program that still changes the machine on a schedule is the
    # worst thing this could possibly leave behind.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        try {
            Write-FedLog "Removing the boot guard needs administrator rights. Asking for them." -Level "INFO" -Component "Watchdog"
            $p = Start-Process -FilePath "schtasks.exe" -ArgumentList "/Delete /TN `"$taskName`" /F" -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
            if (-not (Test-FedWatchdogTaskExists -TaskName $taskName)) {
                Set-FedWatchdogState -Values @{ Installed = $false }
                Write-FedLog "Unregistered watchdog task '$taskName'." -Level "SUCCESS" -Component "Watchdog"
                return $true
            }
        } catch {
            Write-FedLog "Elevation was declined, so the boot guard is still registered." -Level "WARN" -Component "Watchdog"
        }
    }

    # Said plainly, because the consequence is that something keeps running.
    Write-FedLog "The boot guard '$taskName' could not be removed and is still registered. It runs as SYSTEM and will keep re-applying these settings. Remove it from an elevated session with: schtasks /Delete /TN `"$taskName`" /F" -Level "ERROR" -Component "Watchdog"
    return $false
}

function Test-FedWatchdogTaskExists {
    <#
    .SYNOPSIS
        Whether the boot guard is registered, from a session that may not see it.
    .DESCRIPTION
        An ordinary session is refused when it asks about a task owned by
        SYSTEM. Refused is not the same as absent, and treating it as absent is
        how a guard that could not be deleted came to be reported as deleted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { return $true }

    # schtasks distinguishes the two cases in a way the cmdlet does not: being
    # told access is denied means there is something there to be denied about.
    $out = (& schtasks.exe /Query /TN $TaskName 2>&1 | Out-String)
    if ($out -match 'Access is denied') { return $true }
    return $false
}

Export-ModuleMember -Function Get-FedWatchdogStatus, Format-FedWatchdogStatus, Get-FedWatchdogState, Set-FedWatchdogState, Get-FedWatchdogAudit, Enforce-FedWatchdog, Install-FedWatchdogTask, Uninstall-FedWatchdogTask, Test-FedWatchdogTaskExists -ErrorAction SilentlyContinue
