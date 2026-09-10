# ==============================================================================
# FedUpDate Scheduled Automation Engine
# Configures and manages native Windows Scheduled Tasks for automated updates
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"

function Get-FedWindowsPowerShellPath {
    <#
    .SYNOPSIS
        Windows PowerShell, for a task that runs as SYSTEM.
    .DESCRIPTION
        A task used to be pointed at whichever PowerShell registered it. From a
        PowerShell 7 session that is the Store-installed pwsh, which the SYSTEM
        account generally cannot run, so the task would be registered and then
        never run. Windows PowerShell is on every machine, at one path, and
        runnable by SYSTEM.
    #>
    [CmdletBinding()]
    param()

    return (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
}

function Test-FedElevated {
    <#
    .SYNOPSIS
        Whether this session has administrator rights.
    #>
    [CmdletBinding()]
    param()

    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-FedScheduleConfig {
    <#
    .SYNOPSIS
        Records the schedule in the configuration, once it exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Enabled,
        [string]$Frequency,
        [string]$Time,
        [string]$DayOfWeek,
        [bool]$OnlyOnACPower = $true
    )

    $config = Get-FedConfig
    $config.scheduler.enabled = $Enabled
    if ($Enabled) {
        $config.scheduler.frequency = $Frequency
        $config.scheduler.time = $Time
        $config.scheduler.dayOfWeek = $DayOfWeek
        $config.scheduler.onlyOnACPower = $OnlyOnACPower
    }
    Set-FedConfig -Config $config | Out-Null
}

function Get-FedScheduleTask {
    <#
    .SYNOPSIS
        Whether an automated run is scheduled, and when.
    .DESCRIPTION
        The task runs as SYSTEM, which an ordinary session cannot read. It used
        to be reported as not configured from every such session, registered
        or not, so the command line said one thing and the interface, reading
        the configuration instead, said another. Refused is not absent. The
        task is reported as registered when it is, and the parts that need
        elevation to read are left unclaimed rather than guessed.
    #>
    [CmdletBinding()]
    param()

    $taskName = "FedUpDate-AutoUpdate"
    $config = Get-FedConfig
    $when = "$([string]$config.scheduler.frequency) at $([string]$config.scheduler.time)"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if (-not $task) {
        if (Test-FedWatchdogTaskExists -TaskName $taskName) {
            return [PSCustomObject]@{
                IsConfigured = $true
                TaskName     = $taskName
                Status       = "Registered"
                NextRunTime  = $null
                Frequency    = [string]$config.scheduler.frequency
                Time         = [string]$config.scheduler.time
                Readable     = $false
                Detail       = "Registered, $when. When it next runs cannot be read without elevation."
            }
        }
        return [PSCustomObject]@{
            IsConfigured = $false
            TaskName     = $taskName
            Status       = "Not Configured"
            NextRunTime  = $null
            Frequency    = "None"
            Time         = $null
            Readable     = $true
            Detail       = "No automated run is scheduled."
        }
    }

    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    $next = if ($info -and $info.NextRunTime -and $info.NextRunTime -gt [datetime]::MinValue) { $info.NextRunTime.ToString("yyyy-MM-dd HH:mm") } else { $null }
    return [PSCustomObject]@{
        IsConfigured = $true
        TaskName     = $taskName
        Status       = $task.State.ToString()
        NextRunTime  = $next
        LastRunTime  = if ($info -and $info.LastRunTime) { $info.LastRunTime.ToString("yyyy-MM-dd HH:mm") } else { $null }
        LastResult   = if ($info) { $info.LastTaskResult } else { $null }
        Frequency    = [string]$config.scheduler.frequency
        Time         = [string]$config.scheduler.time
        Readable     = $true
        Detail       = if ($next) { "Registered, $when. Next run $next." } else { "Registered, $when." }
    }
}

function Set-FedScheduleTask {
    <#
    .SYNOPSIS
        Schedules the automated update run.
    .DESCRIPTION
        Registering a task that runs as SYSTEM needs administrator rights. This
        used to go ahead without them: the refusal is not an error that stops
        anything, so the configuration was written as enabled and success was
        logged while nothing had been registered, from every interface. Now it
        asks, the way enforcing the shield asks, and reports configured only
        once the task has been asked for back and is there.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet("Daily", "Weekly", "OnIdle")]
        [string]$Frequency = "Daily",

        [Parameter()]
        [string]$Time = "02:00",

        [Parameter()]
        [string]$DayOfWeek = "Sunday",

        [Parameter()]
        [switch]$OnlyOnACPower = $true,

        [Parameter()]
        [switch]$WhatIf
    )

    $taskName = "FedUpDate-AutoUpdate"
    $scriptRoot = Split-Path -Parent $PSScriptRoot
    $cliScript = Join-Path $scriptRoot "fedupdate.ps1"

    $pwshPath = Get-FedWindowsPowerShellPath
    $actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" update --all"

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would register Scheduled Task '$taskName' ($Frequency at $Time) -> $pwshPath $actionArgs" -Level "WHATIF" -Component "Scheduler"
        return $true
    }

    if (-not (Test-FedElevated)) {
        try {
            Write-FedLog "Scheduling an automated run needs administrator rights. Asking for them." -Level "INFO" -Component "Scheduler"
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" schedule set -Frequency `"$Frequency`" -Time `"$Time`" -DayOfWeek `"$DayOfWeek`""
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
            if ($null -ne $p -and $p.ExitCode -eq 0 -and (Test-FedWatchdogTaskExists -TaskName $taskName)) {
                Set-FedScheduleConfig -Enabled $true -Frequency $Frequency -Time $Time -DayOfWeek $DayOfWeek -OnlyOnACPower ([bool]$OnlyOnACPower)
                Write-FedLog "Configured automated update schedule: $Frequency at $Time, verified present." -Level "SUCCESS" -Component "Scheduler"
                return $true
            }
            Write-FedLog "The automated run was not scheduled. The elevated registration did not leave a task behind." -Level "ERROR" -Component "Scheduler"
        } catch {
            Write-FedLog "Elevation was declined, so no automated run was scheduled." -Level "WARN" -Component "Scheduler"
        }
        return $false
    }

    try {
        $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $actionArgs

        $trigger = switch ($Frequency) {
            "Daily" {
                New-ScheduledTaskTrigger -Daily -At $Time
            }
            "Weekly" {
                New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $Time
            }
            "OnIdle" {
                New-ScheduledTaskTrigger -AtLogOn
            }
            Default {
                New-ScheduledTaskTrigger -Daily -At $Time
            }
        }

        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -DontStopIfGoingOnBatteries:(-not $OnlyOnACPower) -StartWhenAvailable -MultipleInstances Parallel

        # -ErrorAction Stop because registration can fail without throwing, and
        # the result is piped away. Without it a refusal was silently discarded.
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

        # Asking for it back is the only proof it is there.
        if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
            Write-FedLog "Registration reported no error, but the task is not present afterwards. No automated run is scheduled." -Level "ERROR" -Component "Scheduler"
            return $false
        }

        Set-FedScheduleConfig -Enabled $true -Frequency $Frequency -Time $Time -DayOfWeek $DayOfWeek -OnlyOnACPower ([bool]$OnlyOnACPower)
        Write-FedLog "Configured automated update schedule: $Frequency at $Time, verified present." -Level "SUCCESS" -Component "Scheduler"
        return $true
    } catch {
        Write-FedLog "Failed to register scheduled update task: $_" -Level "ERROR" -Component "Scheduler"
        return $false
    }
}

function Remove-FedScheduleTask {
    <#
    .SYNOPSIS
        Removes the automated update run.
    .DESCRIPTION
        The same rights are needed to remove the task as to register it, and
        the same false success was reported without them. A task that is not
        there needs no rights: the setting is turned off so it no longer
        claims otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf
    )

    $taskName = "FedUpDate-AutoUpdate"
    $scriptRoot = Split-Path -Parent $PSScriptRoot
    $cliScript = Join-Path $scriptRoot "fedupdate.ps1"

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would remove Scheduled Task '$taskName'" -Level "WHATIF" -Component "Scheduler"
        return $true
    }

    if (-not (Test-FedWatchdogTaskExists -TaskName $taskName)) {
        Set-FedScheduleConfig -Enabled $false
        Write-FedLog "No automated run was scheduled. The setting is now off." -Level "INFO" -Component "Scheduler"
        return $true
    }

    if (-not (Test-FedElevated)) {
        try {
            Write-FedLog "Removing the automated run needs administrator rights. Asking for them." -Level "INFO" -Component "Scheduler"
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" schedule remove" -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
            if ($null -ne $p -and $p.ExitCode -eq 0 -and -not (Test-FedWatchdogTaskExists -TaskName $taskName)) {
                Set-FedScheduleConfig -Enabled $false
                Write-FedLog "Removed automated update schedule task, verified gone." -Level "SUCCESS" -Component "Scheduler"
                return $true
            }
            Write-FedLog "The automated run is still scheduled. The elevated removal did not remove it." -Level "ERROR" -Component "Scheduler"
        } catch {
            Write-FedLog "Elevation was declined, so the automated run is still scheduled." -Level "WARN" -Component "Scheduler"
        }
        return $false
    }

    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Write-FedLog "Removal reported no error, but the task is still present afterwards." -Level "ERROR" -Component "Scheduler"
            return $false
        }
        Set-FedScheduleConfig -Enabled $false
        Write-FedLog "Removed automated update schedule task, verified gone." -Level "SUCCESS" -Component "Scheduler"
        return $true
    } catch {
        Write-FedLog "Failed to remove scheduled update task: $_" -Level "ERROR" -Component "Scheduler"
        return $false
    }
}

Export-ModuleMember -Function Get-FedScheduleTask, Set-FedScheduleTask, Remove-FedScheduleTask, Get-FedWindowsPowerShellPath, Test-FedElevated, Set-FedScheduleConfig -ErrorAction SilentlyContinue