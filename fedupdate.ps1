<#
.SYNOPSIS
    FedUpDate (fedupdate) - Unified Windows 10/11 Update & Anti-Tamper Orchestrator
.DESCRIPTION
    Unifies Windows Update, WinGet, Microsoft Store, Smart Reboot Management,
    Anti-Tamper state watchdog, and 1-Click Rollback with 100% transparent execution.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("scan", "check", "update", "watchdog", "rollback", "schedule", "config", "logs", "version", "self-update", "tui", "gui", "uninstall", "help")]
    [string]$Command = "tui",

    [Parameter()]
    [Alias("a")]
    [switch]$All,

    [Parameter()]
    [switch]$OS,

    [Parameter()]
    [Alias("w", "apps")]
    [switch]$Winget,

    [Parameter()]
    [Alias("s", "msstore")]
    [switch]$Store,

    [Parameter()]
    [Alias("pkg")]
    [string[]]$Packages,

    [Parameter()]
    [Alias("policy")]
    [string]$RebootPolicy,

    [Parameter()]
    [switch]$NoReboot,

    [Parameter()]
    [switch]$ForceReboot,

    [Parameter()]
    [switch]$Shutdown,

    [Parameter()]
    [switch]$WhatIf,

    [Parameter(Position = 1)]
    [string]$Action = "audit",

    [Parameter()]
    [switch]$Latest,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$TransactionId,

    [Parameter()]
    [string]$Frequency = "Daily",

    [Parameter()]
    [string]$Time = "02:00",

    [Parameter()]
    [int]$Count = 50
)

$ErrorActionPreference = "Stop"

# Import Master Engine
$engineModule = Join-Path $PSScriptRoot "core\Engine.psm1"
if (-not (Test-Path $engineModule)) {
    Write-Error "FedUpDate Engine module not found at: $engineModule"
    exit 1
}
Import-Module $engineModule -Force -DisableNameChecking

# Route Commands
$isWhatIf = $WhatIf.IsPresent

switch ($Command.ToLower()) {
    "scan" {
        $result = Start-FedScan
        Write-Host "`n`e[1;36m=== FEDUPDATE SCAN SUMMARY ===`e[0m"
        Write-Host "OS Updates Pending:          $($result.OSUpdateCount)"
        Write-Host "WinGet Updates Pending:      $($result.WingetUpdateCount)"
        Write-Host "Microsoft Store Updates:     $($result.StoreUpdateCount)"
        Write-Host "Microsoft Store App:         $(if ($result.StoreInstalled) { "Installed (v$($result.StoreVersion))" } else { "Not Available" })"
        Write-Host "Reboot Required:             $($result.IsRebootRequired)"
        Write-Host "Anti-Tamper Drift:           $($result.WatchdogDrifted)`n"
    }
    "check" {
        $result = Start-FedScan
        if ($result.OSUpdateCount -gt 0 -or $result.WingetUpdateCount -gt 0 -or $result.StoreUpdateCount -gt 0) {
            Write-Host "[!] Updates are pending across system engines." -ForegroundColor Yellow
            exit 1
        } else {
            Write-Host "[OK] System is fully up to date." -ForegroundColor Green
            exit 0
        }
    }
    "update" {
        $rebootPol = if ($NoReboot) { "Never" } elseif ($Shutdown) { "Shutdown" } elseif ($ForceReboot) { "Force" } elseif ($RebootPolicy) { $RebootPolicy } else { $null }
        $res = Start-FedUpdate `
            -All:($All -or (-not ($OS -or $Winget -or $Store))) `
            -OS:$OS `
            -Winget:$Winget `
            -Store:$Store `
            -WingetPackageIds $Packages `
            -RebootPolicyOverride $rebootPol `
            -WhatIf:$isWhatIf
    }
    "watchdog" {
        switch ($Action.ToLower()) {
            "enforce" {
                $enforceRes = Enforce-FedWatchdog -WhatIf:$isWhatIf
                Write-Host "`n[OK] Anti-Tamper desired state enforced." -ForegroundColor Green
            }
            "install-task" {
                Install-FedWatchdogTask -WhatIf:$isWhatIf
            }
            "remove-task" {
                Uninstall-FedWatchdogTask -WhatIf:$isWhatIf
            }
            Default {
                $audit = Get-FedWatchdogAudit
                Write-Host "`n=== ANTI-TAMPER POLICY AUDIT ===" -ForegroundColor Cyan
                Write-Host "Policy Drift Detected: $($audit.HasDrifted)"
                foreach ($item in $audit.DriftItems) {
                    Write-Host " - [DRIFT] $item" -ForegroundColor Yellow
                }
                if (-not $audit.HasDrifted) {
                    Write-Host "[OK] System policies match hardened desired state." -ForegroundColor Green
                }
                Write-Host ""
            }
        }
    }
    "rollback" {
        if ($Latest) {
            Restore-FedState -Latest -WhatIf:$isWhatIf
        } elseif ($TransactionId) {
            Restore-FedState -TransactionId $TransactionId -WhatIf:$isWhatIf
        } else {
            $ledger = Get-FedLedger
            Write-Host "`n=== FEDUPDATE SYSTEM STATE LEDGER ===" -ForegroundColor Cyan
            foreach ($tx in $ledger) {
                Write-Host "[$($tx.Timestamp)] ID: $($tx.Id) | Trigger: $($tx.Trigger) | Changes: $($tx.Changes.Count)"
            }
            Write-Host "`nUse: fedupdate rollback -Latest (or -TransactionId <ID>)`n"
        }
    }
    "schedule" {
        switch ($Action.ToLower()) {
            "set" {
                Set-FedScheduleTask -Frequency $Frequency -Time $Time -WhatIf:$isWhatIf
            }
            "remove" {
                Remove-FedScheduleTask -WhatIf:$isWhatIf
            }
            Default {
                $task = Get-FedScheduleTask
                Write-Host "`n=== FEDUPDATE AUTOMATION SCHEDULE ===" -ForegroundColor Cyan
                Write-Host "Configured: $($task.IsConfigured)"
                Write-Host "Status:     $($task.Status)"
                Write-Host "Next Run:   $($task.NextRunTime)`n"
            }
        }
    }
    "version" {
        $status = Get-FedVersionStatus
        Write-Host ""
        Write-Host "FedUpDate $($status.Current)" -ForegroundColor Cyan
        if (-not $status.RemoteReachable) {
            Write-Host "  Could not reach GitHub to check for updates." -ForegroundColor Yellow
        } elseif ($status.UpdateAvailable) {
            Write-Host "  Update available: $($status.Latest)" -ForegroundColor Yellow
            Write-Host "  $($status.ReleaseUrl)" -ForegroundColor Gray
            Write-Host "  Run 'fedupdate self-update' to install it." -ForegroundColor Gray
        } else {
            Write-Host "  Up to date." -ForegroundColor Green
        }
        Write-Host ""
    }
    "self-update" {
        Invoke-FedSelfUpdate -Force:$Force -WhatIf:$isWhatIf | Out-Null
    }
    "config" {
        $cfg = Get-FedConfig
        $cfg | ConvertTo-Json -Depth 5
    }
    "logs" {
        $recentLogs = Get-FedLogs -Count $Count
        foreach ($l in $recentLogs) {
            Write-Host "[$($l.Timestamp)] [$($l.Level)] [$($l.Component)] $($l.Message)"
        }
    }
    "tui" {
        . "$PSScriptRoot\tui\TuiEngine.ps1"
        Start-FedTUI
    }
    "gui" {
        $exePath = Join-Path $PSScriptRoot "gui\bin\FedUpDate.UI.exe"
        if (Test-Path $exePath) {
            Start-Process -FilePath $exePath
        } else {
            . "$PSScriptRoot\gui\Server.ps1"
        }
    }
    "uninstall" {
        $installer = Join-Path $PSScriptRoot "install.ps1"
        & $installer -Uninstall
    }
    "help" {
        Write-Host @"
FedUpDate (fedupdate) CLI Help:
  fedupdate scan                      Deep audit of OS updates, WinGet packages, Store, reboot flags
  fedupdate update -All [-WhatIf]     Run unified updates across all 3 engines
  fedupdate update -OS                Update Windows OS & Defender definitions only
  fedupdate update -Winget            Update WinGet packages only
  fedupdate update -Store             Trigger Microsoft Store background sync only
  fedupdate watchdog [audit|enforce]  Audit or enforce anti-tamper update policies
  fedupdate rollback [-Latest]        Rollback registry and service states to previous snapshots
  fedupdate schedule [set|remove]     Manage automated update scheduled tasks
  fedupdate logs [-Count N]           Show recent execution log entries
  fedupdate config                    Print the active configuration
  fedupdate version                   Show the installed version and check for updates
  fedupdate self-update               Update FedUpDate in place to the latest release
  fedupdate tui                       Interactive Terminal UI dashboard
  fedupdate gui                       Launch modern Fluent 2 Desktop Window
  fedupdate uninstall                 Uninstall, with OS restore and backup options
"@
    }
    Default {
        . "$PSScriptRoot\tui\TuiEngine.ps1"
        Start-FedTUI
    }
}
