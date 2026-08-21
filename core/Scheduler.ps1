# ==============================================================================
# FedUpDate Scheduled Automation Engine
# Configures and manages native Windows Scheduled Tasks for automated updates
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"

function Get-FedScheduleTask {
    [CmdletBinding()]
    param()

    $taskName = "FedUpDate-AutoUpdate"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if (-not $task) {
        return [PSCustomObject]@{
            IsConfigured = $false
            TaskName     = $taskName
            Status       = "Not Configured"
            NextRunTime  = $null
            Frequency    = "None"
        }
    }

    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        IsConfigured = $true
        TaskName     = $taskName
        Status       = $task.State.ToString()
        NextRunTime  = if ($info) { $info.NextRunTime } else { $null }
        LastRunTime  = if ($info) { $info.LastRunTime } else { $null }
        LastResult   = if ($info) { $info.LastTaskResult } else { $null }
    }
}

function Set-FedScheduleTask {
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

    $pwshPath = (Get-Process -Id $PID).Path
    $actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$cliScript`" update --all"

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would register Scheduled Task '$taskName' ($Frequency at $Time) -> $pwshPath $actionArgs" -Level "WHATIF" -Component "Scheduler"
        return $true
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

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        
        # Update config
        $config = Get-FedConfig
        $config.scheduler.enabled = $true
        $config.scheduler.frequency = $Frequency
        $config.scheduler.time = $Time
        $config.scheduler.dayOfWeek = $DayOfWeek
        $config.scheduler.onlyOnACPower = $OnlyOnACPower.IsPresent
        Set-FedConfig -Config $config | Out-Null

        Write-FedLog "Configured automated update schedule: $Frequency at $Time." -Level "SUCCESS" -Component "Scheduler"
        return $true
    } catch {
        Write-FedLog "Failed to register scheduled update task: $_" -Level "ERROR" -Component "Scheduler"
        return $false
    }
}

function Remove-FedScheduleTask {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$WhatIf
    )

    $taskName = "FedUpDate-AutoUpdate"
    if ($WhatIf) {
        Write-FedLog "[WHATIF] Would remove Scheduled Task '$taskName'" -Level "WHATIF" -Component "Scheduler"
        return $true
    }

    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        
        $config = Get-FedConfig
        $config.scheduler.enabled = $false
        Set-FedConfig -Config $config | Out-Null

        Write-FedLog "Removed automated update schedule task." -Level "SUCCESS" -Component "Scheduler"
        return $true
    } catch {
        Write-FedLog "Failed to remove scheduled update task: $_" -Level "ERROR" -Component "Scheduler"
        return $false
    }
}

Export-ModuleMember -Function Get-FedScheduleTask, Set-FedScheduleTask, Remove-FedScheduleTask -ErrorAction SilentlyContinue
