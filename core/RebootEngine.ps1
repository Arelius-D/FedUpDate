# ==============================================================================
# FedUpDate Smart Reboot Detection & Policy Engine
# Deep multi-registry inspection of pending reboot states and smart policy handler
# ==============================================================================

. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Config.ps1"

function Get-FedRebootState {
    [CmdletBinding()]
    param()

    $reasons = [System.Collections.Generic.List[string]]::new()
    $isPending = $false
    $pendingFiles = @()

    # 1. Component Based Servicing (CBS)
    try {
        $cbsKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing"
        if (Test-Path "$cbsKey\RebootPending") {
            $isPending = $true
            $reasons.Add("CBS (Component Based Servicing) has pending service updates")
        }
        if (Test-Path "$cbsKey\RebootInProgress") {
            $isPending = $true
            $reasons.Add("CBS updates are currently in-progress across reboot")
        }
    } catch { }

    # 2. Windows Update Auto Update
    try {
        $wuKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"
        if (Test-Path "$wuKey\RebootRequired") {
            $isPending = $true
            $reasons.Add("Windows Update Auto-Update flags a pending system reboot")
        }
        if (Test-Path "$wuKey\PostRebootReporting") {
            # Non-blocking, but good for context
        }
    } catch { }

    # 3. Session Manager Pending File Rename Operations
    try {
        $smKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $item = Get-ItemProperty -Path $smKey -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($null -ne $item -and $null -ne $item.PendingFileRenameOperations) {
            $files = @($item.PendingFileRenameOperations | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($files.Count -gt 0) {
                $isPending = $true
                $pendingFiles = $files
                $reasons.Add("Session Manager has $($files.Count) Pending File Rename Operations")
            }
        }
    } catch { }

    # 4. System Center / Server Manager
    try {
        $smMgr = "HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentState"
        if (Test-Path $smMgr) {
            $val = (Get-ItemProperty $smMgr -ErrorAction SilentlyContinue).IsRebootRequired
            if ($val -eq 1 -or $val -eq $true) {
                $isPending = $true
                $reasons.Add("Server Manager reports reboot required")
            }
        }
    } catch { }

    return [PSCustomObject]@{
        IsRebootRequired = $isPending
        ReasonCount      = $reasons.Count
        Reasons          = @($reasons)
        PendingFiles     = $pendingFiles
    }
}

function Invoke-FedRebootPolicy {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PolicyOverride,

        [Parameter()]
        [switch]$WhatIf
    )

    $state = Get-FedRebootState
    if (-not $state.IsRebootRequired) {
        Write-FedLog "Reboot check passed: No reboot is currently pending." -Level "SUCCESS" -Component "Reboot"
        return [PSCustomObject]@{ Action = "None"; RebootTriggered = $false }
    }

    $config = Get-FedConfig
    $policy = if ($PolicyOverride) { $PolicyOverride } else { $config.rebootPolicy }

    Write-FedLog "System reboot is required ($($state.Reasons -join '; ')). Policy: $policy" -Level "WARN" -Component "Reboot"

    if ($WhatIf) {
        Write-FedLog "[WHATIF] Reboot Policy '$policy' would be evaluated for pending reboot." -Level "WHATIF" -Component "Reboot"
        return [PSCustomObject]@{ Action = $policy; RebootTriggered = $false; WhatIf = $true }
    }

    switch ($policy) {
        "Never" {
            Write-FedLog "Policy is 'Never': Suppressing all reboot actions." -Level "INFO" -Component "Reboot"
            return [PSCustomObject]@{ Action = "Suppressed"; RebootTriggered = $false }
        }
        "Notify" {
            Write-FedLog "Policy is 'Notify': Updates installed. Please reboot your computer when convenient." -Level "WARN" -Component "Reboot"
            try {
                [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
            } catch { }
            return [PSCustomObject]@{ Action = "Notified"; RebootTriggered = $false }
        }
        "Force" {
            Write-FedLog "Policy is 'Force': Initiating immediate system restart..." -Level "WARN" -Component "Reboot"
            Restart-Computer -Force -Confirm:$false
            return [PSCustomObject]@{ Action = "RestartInitiated"; RebootTriggered = $true }
        }
        "Shutdown" {
            Write-FedLog "Policy is 'Shutdown': Initiating immediate system shutdown..." -Level "WARN" -Component "Reboot"
            Stop-Computer -Force -Confirm:$false
            return [PSCustomObject]@{ Action = "ShutdownInitiated"; RebootTriggered = $true }
        }
        "Schedule" {
            $schedTime = $config.rebootScheduleTime
            Write-FedLog "Policy is 'Schedule': Scheduling reboot for $schedTime" -Level "INFO" -Component "Reboot"
            return [PSCustomObject]@{ Action = "Scheduled"; ScheduleTime = $schedTime; RebootTriggered = $false }
        }
        Default {
            Write-FedLog "Defaulting to Notify. Reboot is pending." -Level "INFO" -Component "Reboot"
            return [PSCustomObject]@{ Action = "Notified"; RebootTriggered = $false }
        }
    }
}

Export-ModuleMember -Function Get-FedRebootState, Invoke-FedRebootPolicy -ErrorAction SilentlyContinue
