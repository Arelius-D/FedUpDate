# ==============================================================================
# FedUpDate Interactive Terminal User Interface (TUI)
# High-speed, keyboard-driven ANSI console interface with interactive menus
# ==============================================================================

Import-Module (Join-Path $PSScriptRoot "..\core\Engine.psm1") -Force -DisableNameChecking

function Show-FedHeader {
    Clear-Host
    $title = @"
`e[38;2;99;102;241m    ______         __  __        ____        __       
   / ____/__  ____/ / / /_  __  / __ \____ _/ /____   
  / /_  / _ \/ __  / / / / / / / / / / __ `/ __/ _ \  
 / __/ /  __/ /_/ / /_/ /_/ / / /_/ / /_/ / /_/  __/  
/_/    \___/\__,_/  \__,___/ /_____/\__,_/\__/\___/   
    `e[38;2;139;92;246mv0.1.0-beta | Unified Windows Update & Anti-Tamper Suite`e[0m
"@
    Write-Host $title
    Write-Host "`e[90m--------------------------------------------------------------------------------`e[0m"
}

function Show-FedStatusBar {
    param($ScanResult)

    if ($null -eq $ScanResult) {
        $reboot = Get-FedRebootState
        $rebootBadge = if ($reboot.IsRebootRequired) { "`e[41;97m PENDING REBOOT `e[0m" } else { "`e[42;30m CLEAN `e[0m" }
        Write-Host " Status: $rebootBadge | Ready for scan or update"
    } else {
        $osCount = $ScanResult.OSUpdateCount
        $wgCount = $ScanResult.WingetUpdateCount
        $rebootBadge = if ($ScanResult.IsRebootRequired) { "`e[41;97m PENDING REBOOT `e[0m" } else { "`e[42;30m CLEAN `e[0m" }
        $guardBadge = if ($ScanResult.WatchdogDrifted) { "`e[43;30m DRIFT DETECTED `e[0m" } else { "`e[42;30m SHIELD ACTIVE `e[0m" }

        Write-Host " `e[1mOS Updates:`e[0m `e[36m$osCount KBs`e[0m | `e[1mWinGet:`e[0m `e[35m$wgCount Apps`e[0m | `e[1mStore:`e[0m `e[32mSynced`e[0m | `e[1mReboot:`e[0m $rebootBadge | `e[1mGuard:`e[0m $guardBadge"
    }
    Write-Host "`e[90m--------------------------------------------------------------------------------`e[0m"
}

function Start-FedTUI {
    [CmdletBinding()]
    param()

    $running = $true
    $lastScan = $null

    while ($running) {
        Show-FedHeader
        Show-FedStatusBar -ScanResult $lastScan

        Write-Host "`e[1;37mMAIN MENU`e[0m"
        Write-Host " `e[38;2;99;102;241m[1]`e[0m `e[1mUpdate All`e[0m (Executes OS + WinGet + Store + Post-Check)"
        Write-Host " `e[38;2;139;92;246m[2]`e[0m `e[1mWhatIf Simulation`e[0m (Simulate an update run without touching the system)"
        Write-Host " `e[38;2;59;130;246m[3]`e[0m `e[1mScan & Audit System`e[0m (Deep check of all 3 engines & reboot flags)"
        Write-Host " `e[38;2;16;185;129m[4]`e[0m `e[1mAnti-Tamper Watchdog Center`e[0m (Lock down Windows update auto-hijackers)"
        Write-Host " `e[38;2;245;158;11m[5]`e[0m `e[1mRollback & State Ledger`e[0m (1-Click restore of original OS settings/registry)"
        Write-Host " `e[38;2;236;72;153m[6]`e[0m `e[1mTask Scheduler Automation`e[0m (Configure automated background runs)"
        Write-Host " `e[38;2;14;165;233m[7]`e[0m `e[1mLaunch Modern Desktop GUI`e[0m (Open Fluent 2 Desktop Window)"
        Write-Host " `e[38;2;107;114;128m[8]`e[0m `e[1mView System Logs`e[0m (Browse real-time rolling logs)"
        Write-Host " `e[91m[Q]`e[0m `e[1mQuit`e[0m"
        Write-Host ""
        Write-Host -NoNewline "`e[1;36mSelect an option [1-8, Q]: `e[0m"

        $choice = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
        Write-Host $choice

        switch ($choice) {
            "1" {
                Write-Host "`n`e[33mExecuting Unified Update All...`e[0m`n"
                Start-FedUpdate -All
                $lastScan = Start-FedScan
                Write-Host "`n`e[90mPress any key to continue...`e[0m"
                [Console]::ReadKey($true) | Out-Null
            }
            "2" {
                Write-Host "`n`e[35mRunning WhatIf Simulation...`e[0m`n"
                Start-FedUpdate -All -WhatIf
                Write-Host "`n`e[90mPress any key to continue...`e[0m"
                [Console]::ReadKey($true) | Out-Null
            }
            "3" {
                Write-Host "`n`e[36mScanning system across all 3 engines...`e[0m`n"
                $lastScan = Start-FedScan
                
                Write-Host "`n`e[1;37m--- OS Updates Pending ---`e[0m"
                if ($lastScan.OSUpdates.Count -eq 0) {
                    Write-Host " `e[32mNo pending Windows OS updates.`e[0m"
                } else {
                    foreach ($u in $lastScan.OSUpdates) {
                        Write-Host " - `e[36m$($u.KB)`e[0m: $($u.Title) [$($u.SizeMB) MB]"
                    }
                }

                Write-Host "`n`e[1;37m--- WinGet Updates Available ---`e[0m"
                if ($lastScan.WingetUpdates.Count -eq 0) {
                    Write-Host " `e[32mAll WinGet packages are up to date.`e[0m"
                } else {
                    foreach ($w in $lastScan.WingetUpdates) {
                        Write-Host " - `e[35m$($w.Name)`e[0m ($($w.Id)): `e[90m$($w.CurrentVersion)`e[0m -> `e[32m$($w.AvailableVersion)`e[0m"
                    }
                }

                Write-Host "`n`e[1;37m--- Reboot Flags ---`e[0m"
                if ($lastScan.IsRebootRequired) {
                    Write-Host " `e[91mPending Reboot Required:`e[0m $($lastScan.RebootReasons -join '; ')"
                } else {
                    Write-Host " `e[32mNo pending reboot required.`e[0m"
                }

                Write-Host "`n`e[90mPress any key to continue...`e[0m"
                [Console]::ReadKey($true) | Out-Null
            }
            "4" {
                Show-FedHeader
                Write-Host "`e[1;37mANTI-TAMPER WATCHDOG CENTER`e[0m`n"
                $audit = Get-FedWatchdogAudit
                Write-Host "Audit Results:"
                foreach ($item in $audit.AuditItems) {
                    $driftStr = if ($item.Drifted) { "`e[91m[DRIFTED]`e[0m" } else { "`e[32m[OK]`e[0m" }
                    Write-Host " $driftStr $($item.Name) -> Expected: $($item.Expected) | Actual: $($item.Actual)"
                }
                Write-Host "`nOptions:"
                Write-Host " [E] Enforce Watchdog Policies Now"
                Write-Host " [W] WhatIf / Simulate Enforcement"
                Write-Host " [I] Install On-Boot Startup Persistence Task"
                Write-Host " [U] Uninstall Startup Persistence Task"
                Write-Host " [B] Back to Main Menu"
                Write-Host -NoNewline "`nSelect [E/W/I/U/B]: "
                $sub = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
                Write-Host $sub
                switch ($sub) {
                    "E" { Enforce-FedWatchdog }
                    "W" { Enforce-FedWatchdog -WhatIf }
                    "I" { Install-FedWatchdogTask }
                    "U" { Uninstall-FedWatchdogTask }
                }
                Write-Host "`n`e[90mPress any key to continue...`e[0m"
                [Console]::ReadKey($true) | Out-Null
            }
            "5" {
                Show-FedHeader
                Write-Host "`e[1;37mROLLBACK & STATE LEDGER`e[0m`n"
                $ledger = @(Get-FedLedger)
                if ($ledger.Count -eq 0) {
                    Write-Host " `e[90mNo state transactions recorded yet.`e[0m"
                } else {
                    Write-Host "Recorded Transactions (Total: $($ledger.Count)):"
                    for ($i = 0; $i -lt [math]::Min(10, $ledger.Count); $i++) {
                        $tx = $ledger[$ledger.Count - 1 - $i]
                        Write-Host " `e[36m$($tx.Id)`e[0m [`e[90m$($tx.Timestamp)`e[0m] - $($tx.Description) ($($tx.Changes.Count) ops)"
                    }
                    Write-Host "`nOptions:"
                    Write-Host " [R] Rollback Most Recent Transaction"
                    Write-Host " [W] WhatIf Rollback"
                    Write-Host " [A] Rollback All Transactions to System Defaults"
                    Write-Host " [B] Back to Main Menu"
                    Write-Host -NoNewline "`nSelect [R/W/A/B]: "
                    $sub = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
                    Write-Host $sub
                    switch ($sub) {
                        "R" { Restore-FedState -Latest }
                        "W" { Restore-FedState -Latest -WhatIf }
                        "A" { Restore-FedState -All }
                    }
                }
                Write-Host "`n`e[90mPress any key to continue...`e[0m"
                [Console]::ReadKey($true) | Out-Null
            }
            "6" {
                Show-FedHeader
                Write-Host "`e[1;37mTASK SCHEDULER AUTOMATION`e[0m`n"
                $sched = Get-FedScheduleTask
                Write-Host "Current Schedule Status: $($sched.Status)"
                if ($sched.IsConfigured) {
                    Write-Host "Next Run: $($sched.NextRunTime)"
                    Write-Host "Last Run: $($sched.LastRunTime) (Result: $($sched.LastResult))"
                }
                Write-Host "`nOptions:"
                Write-Host " [1] Enable Daily Schedule (02:00 AM)"
                Write-Host " [2] Enable Weekly Schedule (Sunday 02:00 AM)"
                Write-Host " [3] Disable Scheduled Task"
                Write-Host " [B] Back to Main Menu"
                Write-Host -NoNewline "`nSelect [1/2/3/B]: "
                $sub = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
                Write-Host $sub
                switch ($sub) {
                    "1" { Set-FedScheduleTask -Frequency "Daily" -Time "02:00" }
                    "2" { Set-FedScheduleTask -Frequency "Weekly" -DayOfWeek "Sunday" -Time "02:00" }
                    "3" { Remove-FedScheduleTask }
                }
                Write-Host "`n`e[90mPress any key to continue...`e[0m"
                [Console]::ReadKey($true) | Out-Null
            }
            "7" {
                Write-Host "`n`e[36mLaunching Modern Desktop GUI...`e[0m`n"
                $scriptRoot = Split-Path -Parent $PSScriptRoot
                $guiScript = Join-Path $scriptRoot "gui\Server.ps1"
                Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$guiScript`""
                Start-Sleep -Seconds 1
            }
            "8" {
                Show-FedHeader
                Write-Host "`e[1;37mRECENT EXECUTION LOGS`e[0m`n"
                $logs = Get-FedLogs -Count 30
                foreach ($l in $logs) {
                    Write-Host "[$($l.Timestamp)] [$($l.Level)] [$($l.Component)] $($l.Message)"
                }
                Write-Host "`n`e[90mPress any key to continue...`e[0m"
                [Console]::ReadKey($true) | Out-Null
            }
            "Q" {
                $running = $false
                Write-Host "`n`e[32mExiting FedUpDate. Stay up to date!`e[0m`n"
            }
        }
    }
}

Export-ModuleMember -Function Start-FedTUI -ErrorAction SilentlyContinue
